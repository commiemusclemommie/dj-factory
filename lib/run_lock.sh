#!/usr/bin/env bash
# lib/run_lock.sh

run_lock_helper_is_alive() {
    local helper_pid="$1"
    local proc_pid
    local proc_state

    [[ "$helper_pid" =~ ^[0-9]+$ ]] || return 1
    [[ -r "/proc/$helper_pid/stat" ]] || return 1
    read -r proc_pid _ proc_state _ < "/proc/$helper_pid/stat" || return 1
    [[ "$proc_pid" == "$helper_pid" && "$proc_state" != Z ]]
}

run_lock_recursive_child_pids() {
    local parent_pid="$1"
    local child_pid

    for child_pid in $(pgrep -P "$parent_pid" 2>/dev/null || true); do
        printf '%s\n' "$child_pid"
        run_lock_recursive_child_pids "$child_pid"
    done
}

run_lock_abort_owner() {
    local owner_pid="$1"
    local watchdog_pid="$2"
    local pid
    local pids=()

    while IFS= read -r pid; do
        [[ -n "$pid" && "$pid" != "$watchdog_pid" ]] && pids+=("$pid")
    done < <(run_lock_recursive_child_pids "$owner_pid" | awk '!seen[$0]++')

    for pid in "${pids[@]}"; do
        kill -TERM "$pid" 2>/dev/null || true
    done
    kill -TERM "$owner_pid" 2>/dev/null || true
}

run_lock_watchdog() {
    local owner_pid="$1"
    local helper_pid="$2"

    while run_lock_helper_is_alive "$helper_pid"; do
        sleep 0.02
    done

    printf '%s\n' "❌ Pipeline lock helper exited unexpectedly; aborting to prevent concurrent mutation." >&2
    run_lock_abort_owner "$owner_pid" "$BASHPID"
}

start_run_lock_watchdog() {
    local owner_pid="$$"
    local helper_pid="$1"

    run_lock_watchdog "$owner_pid" "$helper_pid" &
    RUN_LOCK_WATCHDOG_PID=$!
}

stop_run_lock_watchdog() {
    if [[ -n "${RUN_LOCK_WATCHDOG_PID:-}" ]]; then
        kill -TERM "$RUN_LOCK_WATCHDOG_PID" 2>/dev/null || true
        wait "$RUN_LOCK_WATCHDOG_PID" 2>/dev/null || true
        RUN_LOCK_WATCHDOG_PID=""
    fi
}

acquire_run_lock() {
    local status
    local attempt
    local lock_helper="$ROOT_DIR/scripts/hold_run_lock.py"

    LOCK_FILE="$STATE_DIR/run.lock"
    RUN_LOCK_STATUS_FILE="$LOCK_FILE.status.$$"
    mkdir -p "$STATE_DIR" || die "Failed to prepare pipeline lock directory: $STATE_DIR"
    RUN_LOCK_PYTHON="$(find_python_interpreter "${BOOTSTRAP_PYTHON:-}" python3 python)" || \
        die "Could not find a usable Python interpreter (>= 3.10) for the pipeline run lock."
    [[ -r "$lock_helper" ]] || die "Missing pipeline lock helper: $lock_helper"
    rm -f -- "$RUN_LOCK_STATUS_FILE" || die "Failed to clear pipeline lock status: $RUN_LOCK_STATUS_FILE"

    # Keep the flock in a short-lived helper. The owner shell and every external
    # process it starts therefore have no lock descriptor to inherit. The helper
    # uses PR_SET_PDEATHSIG so a crash or SIGKILL of this owner releases the lock.
    "$RUN_LOCK_PYTHON" "$lock_helper" "$LOCK_FILE" "$RUN_LOCK_STATUS_FILE" "$$" &
    RUN_LOCK_HELPER_PID=$!
    start_run_lock_watchdog "$RUN_LOCK_HELPER_PID"

    for ((attempt = 0; attempt < 100; attempt++)); do
        if [[ -f "$RUN_LOCK_STATUS_FILE" ]]; then
            status="$(<"$RUN_LOCK_STATUS_FILE")"
            case "$status" in
                acquired)
                    rm -f -- "$RUN_LOCK_STATUS_FILE"
                    return 0
                    ;;
                busy)
                    local existing_pid
                    existing_pid="$(head -n 1 "$LOCK_FILE" 2>/dev/null || true)"
                    if [[ -n "$existing_pid" ]]; then
                        die "dj-factory is already running (PID $existing_pid). Stop it with: kill $existing_pid"
                    fi
                    die "dj-factory is already running; could not determine its PID."
                    ;;
                *)
                    die "Failed to acquire pipeline lock: $status"
                    ;;
            esac
        fi
        if ! run_lock_helper_is_alive "$RUN_LOCK_HELPER_PID"; then
            wait "$RUN_LOCK_HELPER_PID" 2>/dev/null || true
            die "Pipeline lock helper exited before acquiring the lock."
        fi
        sleep 0.01
    done

    stop_run_lock_watchdog
    kill -TERM "$RUN_LOCK_HELPER_PID" 2>/dev/null || true
    wait "$RUN_LOCK_HELPER_PID" 2>/dev/null || true
    die "Timed out acquiring pipeline lock."
}
