#!/usr/bin/env bash
# shellcheck disable=SC2218,SC2329  # die is defined before sourced implementations; traps and dynamic PID traversal invoke functions.
# main.sh

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Keep the lock supervisor outside the worker process. If this owner shell is
# SIGKILLed, the supervisor remains alive long enough to terminate and reap
# the worker's process group before releasing flock.
if [[ "${DJ_FACTORY_LOCK_SUPERVISED:-0}" != "1" ]]; then
    lock_python=""
    for candidate in "${BOOTSTRAP_PYTHON:-}" python3 python; do
        [[ -n "$candidate" ]] || continue
        if command -v "$candidate" >/dev/null 2>&1 && \
            "$candidate" -c 'import sys; raise SystemExit(sys.version_info < (3, 10))' >/dev/null 2>&1; then
            lock_python="$(command -v "$candidate")"
            break
        fi
    done
    [[ -n "$lock_python" ]] || {
        echo "Could not find a usable Python interpreter (>= 3.10) for the pipeline lock." >&2
        exit 1
    }
    mkdir -p "$ROOT_DIR/.state" || exit 1
    export DJ_FACTORY_LOCK_SUPERVISED=1
    "$lock_python" "$ROOT_DIR/scripts/hold_run_lock.py" --supervise \
        "$ROOT_DIR/.state/run.lock" "$$" "$ROOT_DIR/main.sh" &
    lock_supervisor_pid=$!
    wait "$lock_supervisor_pid"
    exit $?
fi

LIB_DIR="$ROOT_DIR/lib"
LOG_DIR="$ROOT_DIR/logs"
LOG_FILE="$LOG_DIR/dj-factory-$(date +%Y%m%d-%H%M%S).log"

mkdir -p "$LOG_DIR"

if command -v tee >/dev/null 2>&1; then
    exec > >(tee -a "$LOG_FILE") 2>&1
else
    exec >>"$LOG_FILE" 2>&1
fi

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

die() {
    echo "$1" >&2
    exit 1
}

recursive_child_pids() {
    local parent_pid="$1"
    local child_pid

    for child_pid in $(pgrep -P "$parent_pid" 2>/dev/null || true); do
        printf '%s\n' "$child_pid"
        recursive_child_pids "$child_pid"
    done
}

terminate_descendants() {
    local pids=()
    local pid

    if [[ -n "${ACTIVE_CHILD_PID:-}" ]] && kill -0 "$ACTIVE_CHILD_PID" 2>/dev/null; then
        kill -TERM "-$ACTIVE_CHILD_PID" 2>/dev/null || true
        kill -TERM "$ACTIVE_CHILD_PID" 2>/dev/null || true
    fi

    while IFS= read -r pid; do
        [[ -n "$pid" ]] && pids+=("$pid")
    done < <(recursive_child_pids "$$" | awk '!seen[$0]++')

    if [[ ${#pids[@]} -gt 0 ]]; then
        kill "${pids[@]}" 2>/dev/null || true
        sleep 1
        if [[ -n "${ACTIVE_CHILD_PID:-}" ]] && kill -0 "$ACTIVE_CHILD_PID" 2>/dev/null; then
            kill -KILL "-$ACTIVE_CHILD_PID" 2>/dev/null || true
            kill -KILL "$ACTIVE_CHILD_PID" 2>/dev/null || true
        fi
        kill -9 "${pids[@]}" 2>/dev/null || true
    fi
}

if [[ "$(uname -s)" != "Linux" ]]; then
    die "DJ_Factory currently supports Linux only."
fi

for required_file in "$LIB_DIR/config.sh" "$LIB_DIR/bootstrap.sh" "$LIB_DIR/processing.sh" "$LIB_DIR/run_lock.sh"; do
    [[ -r "$required_file" ]] || die "Missing required file: $required_file"
done

# shellcheck source=lib/config.sh
source "$LIB_DIR/config.sh"

ensure_distrobox() {
    if command_exists distrobox; then
        return 0
    fi

    echo -e "\033[0;33m⚠️  Distrobox not found. Installing locally...\033[0m"
    command_exists curl || die "Distrobox is required, and curl was not found for local installation."
    curl -fsSL https://raw.githubusercontent.com/89luca89/distrobox/main/install | sh -s -- --prefix "$HOME/.local"
    export PATH="$HOME/.local/bin:$PATH"
    command_exists distrobox || die "Distrobox installation failed."
}

ensure_container_runtime() {
    if command_exists podman || command_exists docker; then
        return 0
    fi
    die "Distrobox requires podman or docker on the host."
}

enter_distrobox_if_needed() {
    if [[ "${USE_DISTROBOX:-1}" != "1" ]]; then
        return 0
    fi

    if [[ -f /run/.containerenv || "${CONTAINER_ID:-}" == "$BOX_NAME" ]]; then
        return 0
    fi

    echo -e "\033[0;36m🔌 HOST DETECTED: routing through Distrobox '$BOX_NAME'...\033[0m"

    ensure_distrobox
    ensure_container_runtime

    if ! distrobox list 2>/dev/null | grep -Eq "(^|[[:space:]])${BOX_NAME}([[:space:]]|$)"; then
        echo -e "\033[0;33m⚠️  Container '$BOX_NAME' missing. Creating from $BOX_IMAGE...\033[0m"
        if ! distrobox create -n "$BOX_NAME" -i "$BOX_IMAGE" --yes; then
            if ! distrobox list 2>/dev/null | grep -Eq "(^|[[:space:]])${BOX_NAME}([[:space:]]|$)"; then
                die "Failed to create Distrobox container '$BOX_NAME'."
            fi
        fi
    fi

    echo -e "\033[0;32m🚀 Entering $BOX_NAME...\033[0m"
    exec distrobox enter "$BOX_NAME" -- env DJ_FACTORY_LOCK_SUPERVISED=1 "$ROOT_DIR/main.sh"
}

enter_distrobox_if_needed

# shellcheck source=lib/bootstrap.sh
source "$LIB_DIR/bootstrap.sh"
# shellcheck source=lib/processing.sh
source "$LIB_DIR/processing.sh"
# shellcheck source=lib/run_lock.sh
source "$LIB_DIR/run_lock.sh"

cleanup() {
    local exit_code=$?

    stop_run_lock_watchdog
    terminate_descendants

    if [[ -n "${RUN_TMP_DIR:-}" && -d "${RUN_TMP_DIR:-}" ]]; then
        rm -rf "$RUN_TMP_DIR"
    fi

    if [[ -n "${RUN_LOCK_HELPER_PID:-}" ]]; then
        kill -TERM "$RUN_LOCK_HELPER_PID" 2>/dev/null || true
        wait "$RUN_LOCK_HELPER_PID" 2>/dev/null || true
    fi
    if [[ -n "${RUN_LOCK_STATUS_FILE:-}" ]]; then
        rm -f -- "$RUN_LOCK_STATUS_FILE"
    fi

    if [[ $exit_code -eq 0 ]]; then
        echo -e "\n${GREEN}✨ Session finished.${NC}"
    else
        echo -e "\n${RED}❌ dj-factory exited with status ${exit_code}.${NC}"
        echo -e "${YELLOW}Log:${NC} $LOG_FILE"
        if [[ -t 0 ]]; then
            read -r -p "Press Enter to close..." _
        fi
    fi
}

handle_signal() {
    exit 130
}

trap cleanup EXIT
trap handle_signal INT TERM

if [[ "${DJ_FACTORY_LOCK_SUPERVISED:-0}" != "1" ]]; then
    acquire_run_lock
fi

echo -e "${CYAN}🧱 DJ_Factory Linux bootstrap${NC}"
echo -e "${YELLOW}Repo:${NC} $ROOT_DIR"
echo -e "${YELLOW}Log :${NC} $LOG_FILE"
if [[ "${USE_DISTROBOX:-1}" == "1" ]]; then
    echo -e "${YELLOW}Mode:${NC} distrobox"
else
    echo -e "${YELLOW}Mode:${NC} local"
fi

setup_environment
create_desktop_shortcut
show_menu
pipeline_status=0
run_pipeline || pipeline_status=$?

read -r -p "Press Enter to close..." || true
exit "$pipeline_status"
