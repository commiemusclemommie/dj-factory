#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034  # The suite intentionally sets globals consumed by sourced pipeline functions.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

if command -v python3 >/dev/null 2>&1; then
    TEST_PYTHON="$(command -v python3)"
elif command -v python >/dev/null 2>&1; then
    TEST_PYTHON="$(command -v python)"
else
    fail "no Python interpreter available for regression tests"
fi

# shellcheck source=../lib/bootstrap.sh
source "$REPO_ROOT/lib/bootstrap.sh"
# shellcheck source=../lib/run_lock.sh
source "$REPO_ROOT/lib/run_lock.sh"
# The empty basename produced by a file named ".m4a" must never resolve to
# the output directory itself.
CURRENT_OUTPUT="$TMP_ROOT/output"
mkdir -p "$CURRENT_OUTPUT"
printf 'keep\n' >"$CURRENT_OUTPUT/sentinel"
# shellcheck source=../lib/processing.sh
source "$REPO_ROOT/lib/processing.sh"
safe_remove_stemgen_work ""
safe_remove_stemgen_work "."
[[ -f "$CURRENT_OUTPUT/sentinel" ]] || fail "unsafe stem cleanup removed the output directory"
mkdir "$CURRENT_OUTPUT/track"
printf 'stale\n' >"$CURRENT_OUTPUT/track.stem.m4a"
safe_remove_stemgen_work "track"
[[ ! -e "$CURRENT_OUTPUT/track" && ! -e "$CURRENT_OUTPUT/track.stem.m4a" ]] || fail "valid stem cleanup did not remove its direct children"

# The run-lock interpreter must use python when python3 is unavailable.
python_only_bin="$TMP_ROOT/python-only-bin"
mkdir -p "$python_only_bin"
for utility in mkdir rm sleep; do
    ln -s "$(command -v "$utility")" "$python_only_bin/$utility"
done
ln -s "$TEST_PYTHON" "$python_only_bin/python"
# shellcheck disable=SC2016  # The child shell intentionally expands its own environment.
if ! PATH="$python_only_bin" REPO_ROOT_FOR_TEST="$REPO_ROOT" \
    STATE_DIR_FOR_TEST="$TMP_ROOT/python-only-state" \
    PYTHON_ONLY_BIN="$python_only_bin" "$(command -v bash)" -c '
        source "$REPO_ROOT_FOR_TEST/lib/bootstrap.sh"
        source "$REPO_ROOT_FOR_TEST/lib/run_lock.sh"
        ROOT_DIR="$REPO_ROOT_FOR_TEST"
        STATE_DIR="$STATE_DIR_FOR_TEST"
        RED= YELLOW= CYAN= NC=
        acquire_run_lock
        [[ "$RUN_LOCK_PYTHON" == "$PYTHON_ONLY_BIN/python" ]]
        stop_run_lock_watchdog
        kill -TERM "$RUN_LOCK_HELPER_PID" 2>/dev/null || true
        wait "$RUN_LOCK_HELPER_PID" 2>/dev/null || true
    '; then
    fail "python fallback did not acquire the run lock"
fi

# A held flock must exclude a second pipeline instance.
lock_path="$TMP_ROOT/run.lock"
(
    exec 9>>"$lock_path"
    flock -n 9
    sleep 2
) &
holder_pid=$!
for _ in {1..20}; do
    flock -n 8>>"$lock_path" 2>/dev/null && fail "second instance acquired the run lock"
    sleep 0.05
done
wait "$holder_pid"

# The lock helper is separate from the owner shell, so an external child cannot
# inherit its descriptor and keep the lock after the owner is SIGKILLed.
lock_helper="$REPO_ROOT/scripts/hold_run_lock.py"
crash_lock="$TMP_ROOT/crash.lock"
crash_ready="$TMP_ROOT/crash.ready"
crash_child="$TMP_ROOT/crash.child"
crash_mutation="$TMP_ROOT/crash.mutation"
cat >"$TMP_ROOT/lock-owner" <<EOF
#!/usr/bin/env bash
"$TEST_PYTHON" "$lock_helper" "$crash_lock" "$crash_ready" "\$\$" &
helper=\$!
while [[ ! -f "$crash_ready" ]]; do sleep 0.01; done
(sleep 2; : >"$crash_mutation") &
printf '%s\\n' "\$!" >"$crash_child"
wait "\$helper"
EOF
chmod +x "$TMP_ROOT/lock-owner"
"$TMP_ROOT/lock-owner" &
crash_owner_pid=$!
for _ in {1..100}; do
    [[ -f "$crash_ready" ]] && break
    sleep 0.01
done
[[ "$(<"$crash_ready")" == acquired ]] || fail "lock helper did not acquire the lock"
for _ in {1..100}; do
    [[ -s "$crash_child" ]] && break
    sleep 0.01
done
[[ -s "$crash_child" ]] || fail "lock owner did not start its external child"
kill -KILL "$crash_owner_pid" 2>/dev/null || true
wait "$crash_owner_pid" 2>/dev/null || true
exec 8>>"$crash_lock"
for _ in {1..100}; do
    if flock -n 8; then
        break
    fi
    sleep 0.01
done
flock -n 8 || fail "lock remained held after owner SIGKILL"
flock -u 8
exec 8>&-
sleep 0.7
[[ ! -e "$crash_mutation" ]] || fail "descendant mutated after owner SIGKILL"

# Losing the helper must stop the owner before it performs its next mutation,
# while a later owner can still acquire the lock.
helper_death_state="$TMP_ROOT/helper-death-state"
mkdir -p "$helper_death_state"
cat >"$TMP_ROOT/supervised-owner" <<EOF
#!/usr/bin/env bash
set -uo pipefail
source "$REPO_ROOT/lib/bootstrap.sh"
source "$REPO_ROOT/lib/run_lock.sh"
ROOT_DIR="$REPO_ROOT"
STATE_DIR="$helper_death_state"
RED= YELLOW= CYAN= NC=
cleanup() {
    local status=\$?
    stop_run_lock_watchdog
    if [[ -n "\${RUN_LOCK_HELPER_PID:-}" ]]; then
        kill -TERM "\$RUN_LOCK_HELPER_PID" 2>/dev/null || true
        wait "\$RUN_LOCK_HELPER_PID" 2>/dev/null || true
    fi
    exit "\$status"
}
trap cleanup EXIT
acquire_run_lock
printf '%s\n' "\$RUN_LOCK_HELPER_PID" >"$helper_death_state/helper.pid"
: >"$helper_death_state/owner.ready"
sleep 30
: >"$helper_death_state/owner.mutated"
EOF
chmod +x "$TMP_ROOT/supervised-owner"
"$TMP_ROOT/supervised-owner" &
supervised_owner_pid=$!
for _ in {1..100}; do
    [[ -f "$helper_death_state/owner.ready" ]] && break
    sleep 0.01
done
[[ -f "$helper_death_state/owner.ready" ]] || fail "supervised owner did not acquire the lock"
kill -KILL "$(<"$helper_death_state/helper.pid")" 2>/dev/null || true
owner_status=0
wait "$supervised_owner_pid" || owner_status=$?
[[ "$owner_status" -ne 0 ]] || fail "owner survived lock-helper death"
[[ ! -e "$helper_death_state/owner.mutated" ]] || fail "owner mutated after lock-helper death"
cat >"$TMP_ROOT/second-owner" <<EOF
#!/usr/bin/env bash
set -uo pipefail
source "$REPO_ROOT/lib/bootstrap.sh"
source "$REPO_ROOT/lib/run_lock.sh"
ROOT_DIR="$REPO_ROOT"
STATE_DIR="$helper_death_state"
RED= YELLOW= CYAN= NC=
acquire_run_lock
: >"$helper_death_state/second.acquired"
stop_run_lock_watchdog
kill -TERM "\$RUN_LOCK_HELPER_PID" 2>/dev/null || true
wait "\$RUN_LOCK_HELPER_PID" 2>/dev/null || true
EOF
chmod +x "$TMP_ROOT/second-owner"
"$TMP_ROOT/second-owner"
[[ -f "$helper_death_state/second.acquired" ]] || fail "second owner could not acquire released lock"

# A tagging exception must be visible to the caller as a failure.
if "$TEST_PYTHON" "$REPO_ROOT/scripts/write_tag.py" "$TMP_ROOT/not-audio.bin" "+5c" >/dev/null 2>&1; then
    fail "tagging failure returned success"
fi

# Tidal download must not run when its config update fails.
input_dir="$TMP_ROOT/input"
output_dir="$TMP_ROOT/output2"
mkdir -p "$input_dir" "$output_dir"
download_marker="$TMP_ROOT/downloaded"
cat >"$TMP_ROOT/tidal" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == dl ]]; then
    : >"$download_marker"
fi
EOF
chmod +x "$TMP_ROOT/tidal"
cat >"$TMP_ROOT/python-fails" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$TMP_ROOT/python-fails"
CURRENT_INPUT="$input_dir"
CURRENT_OUTPUT="$output_dir"
TMP_DIR="$TMP_ROOT/pipeline-tmp"
CURRENT_TIDAL="https://tidal.com/browse/playlist/test"
SCRIPT_DIR="$REPO_ROOT/scripts"
YELLOW='' RED='' GREEN='' CYAN='' NC=''
TIDAL_URL_FILE="$TMP_ROOT/tidal_playlist.txt"
TIDAL_BIN="$TMP_ROOT/tidal"
BOOTSTRAP_PYTHON="$TMP_ROOT/python-fails"
SELECTIONS=(1 0 0 0 0)
if run_pipeline; then
    fail "config failure returned a successful pipeline status"
fi
[[ ! -e "$download_marker" ]] || fail "Tidal download ran after config failure"

# Per-file failures are returned while the file can still be copied and later
# files remain independent.
cat >"$TMP_ROOT/onetagger-fails" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$TMP_ROOT/onetagger-fails"
printf 'audio\n' >"$input_dir/failing.aiff"
BIN_DIR="$TMP_ROOT"
ln -sf "$TMP_ROOT/onetagger-fails" "$TMP_ROOT/onetagger-cli"
ONETAGGER_CONF="$TMP_ROOT/onetagger.json"
FFPROBE_BIN=/bin/false
SELECTIONS=(0 1 0 0 0)
if process_single_file "$input_dir/failing.aiff"; then
    fail "OneTagger failure returned a successful file status"
fi
[[ -f "$output_dir/failing.aiff" ]] || fail "independent file output was not preserved"

# JSON settings are replaced in one completed write and retain no temporary file.
config_home="$TMP_ROOT/home"
mkdir -p "$config_home"
HOME="$config_home" FFMPEG_BIN=/test/ffmpeg \
    "$TEST_PYTHON" "$REPO_ROOT/scripts/update_tidal_config.py" "$input_dir" >/dev/null
"$TEST_PYTHON" - "$config_home/.config/tidal_dl_ng/settings.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as config_file:
    settings = json.load(config_file)
assert settings["download_base_path"].endswith("/input")
assert settings["skip_existing"] is False
PY
[[ -z "$(find "$config_home/.config/tidal_dl_ng" -name '*.tmp' -print -quit)" ]] || fail "temporary config file was left behind"

# A malformed primary falls back to a valid legacy settings file.
fallback_home="$TMP_ROOT/fallback-home"
mkdir -p "$fallback_home/.config/tidal_dl_ng"
printf '{malformed\n' >"$fallback_home/.config/tidal_dl_ng/settings.json"
printf '{"legacy": true}\n' >"$fallback_home/.tidal-dl.json"
HOME="$fallback_home" FFMPEG_BIN=/test/ffmpeg \
    "$TEST_PYTHON" "$REPO_ROOT/scripts/update_tidal_config.py" "$input_dir" >/dev/null
"$TEST_PYTHON" - "$fallback_home/.tidal-dl.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as config_file:
    settings = json.load(config_file)
assert settings["legacy"] is True
assert settings["download_base_path"].endswith("/input")
PY
fallback_primary_text="$(<"$fallback_home/.config/tidal_dl_ng/settings.json")"
[[ "$fallback_primary_text" == '{malformed' ]] || fail "malformed primary was unexpectedly replaced during fallback"

# A malformed-only primary is repaired through the same atomic writer.
malformed_home="$TMP_ROOT/malformed-home"
mkdir -p "$malformed_home/.config/tidal_dl_ng"
printf '{malformed\n' >"$malformed_home/.config/tidal_dl_ng/settings.json"
HOME="$malformed_home" FFMPEG_BIN=/test/ffmpeg \
    "$TEST_PYTHON" "$REPO_ROOT/scripts/update_tidal_config.py" "$input_dir" >/dev/null
"$TEST_PYTHON" - "$malformed_home/.config/tidal_dl_ng/settings.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as config_file:
    settings = json.load(config_file)
assert settings["download_base_path"].endswith("/input")
PY
[[ -z "$(find "$malformed_home/.config/tidal_dl_ng" -name '*.tmp' -print -quit)" ]] || fail "malformed config repair left a temporary file"

# An existing Tidal settings symlink must remain intact while its target is
# atomically replaced.
symlink_target="$TMP_ROOT/tidal-settings-target.json"
printf '{"old": true}\n' >"$symlink_target"
symlink_config="$config_home/.config/tidal_dl_ng/settings.json"
rm -f "$symlink_config"
ln -s "$symlink_target" "$symlink_config"
symlink_text="$(readlink "$symlink_config")"
HOME="$config_home" FFMPEG_BIN=/test/ffmpeg \
    "$TEST_PYTHON" "$REPO_ROOT/scripts/update_tidal_config.py" "$input_dir" >/dev/null
[[ -L "$symlink_config" ]] || fail "Tidal settings symlink was replaced"
[[ "$(readlink "$symlink_config")" == "$symlink_text" ]] || fail "Tidal settings symlink target changed"
"$TEST_PYTHON" - "$symlink_target" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as config_file:
    settings = json.load(config_file)
assert settings["download_base_path"].endswith("/input")
assert settings["old"] is True
PY

# A dangling settings symlink fails without replacing the link.
broken_home="$TMP_ROOT/broken-home"
broken_config="$broken_home/.config/tidal_dl_ng/settings.json"
mkdir -p "$(dirname "$broken_config")"
ln -s "$broken_home/missing-target.json" "$broken_config"
broken_error="$TMP_ROOT/broken-error"
if HOME="$broken_home" "$TEST_PYTHON" "$REPO_ROOT/scripts/update_tidal_config.py" "$input_dir" \
    >/dev/null 2>"$broken_error"; then
    fail "dangling Tidal settings symlink unexpectedly succeeded"
fi
[[ -L "$broken_config" ]] || fail "failed symlink update replaced the symlink"
grep -Fq "settings symlink target" "$broken_error" || fail "symlink failure was not clear"

# Desktop Exec paths are quoted and literal percent signs are doubled per the
# Desktop Entry field-code rules.
launcher_root="$TMP_ROOT/repo % with spaces"
mkdir -p "$launcher_root"
ROOT_DIR="$launcher_root"
XDG_DATA_HOME="$TMP_ROOT/xdg"
source "$REPO_ROOT/lib/bootstrap.sh"
create_desktop_shortcut
launcher="$XDG_DATA_HOME/applications/DJ_Factory.desktop"
escaped_launcher_root="${launcher_root//%/%%}"
grep -Fq "Exec=\"$escaped_launcher_root/main.sh\"" "$launcher" || fail "desktop Exec path was not escaped"
grep -Fq '%%' "$launcher" || fail "desktop Exec percent was not escaped"

echo "regression tests passed"
