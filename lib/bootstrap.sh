#!/usr/bin/env bash
# lib/bootstrap.sh

log_info() {
    echo -e "${CYAN}$*${NC}"
}

log_warn() {
    echo -e "${YELLOW}$*${NC}" >&2
}

log_error() {
    echo -e "${RED}$*${NC}" >&2
}

die() {
    log_error "$1"
    exit 1
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

run_as_root() {
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        "$@"
    elif command_exists sudo; then
        sudo "$@"
    else
        die "Need sudo/root to install system packages: $*"
    fi
}

detect_package_manager() {
    if command_exists apt-get; then
        echo "apt"
    elif command_exists dnf; then
        echo "dnf"
    elif command_exists pacman; then
        echo "pacman"
    elif command_exists zypper; then
        echo "zypper"
    else
        echo "unknown"
    fi
}

install_linux_packages() {
    local pm="$1"
    shift

    if [[ $# -eq 0 ]]; then
        return 0
    fi

    case "$pm" in
        apt)
            run_as_root apt-get update
            run_as_root apt-get install -y "$@"
            ;;
        dnf)
            run_as_root dnf install -y "$@"
            ;;
        pacman)
            run_as_root pacman -Sy --noconfirm "$@"
            ;;
        zypper)
            run_as_root zypper --non-interactive install "$@"
            ;;
        *)
            return 1
            ;;
    esac
}

is_immutable_linux_host() {
    [[ -e /run/ostree-booted || -e /run/bootc-install/reboot-needed || -d /sysroot/ostree ]]
}

maybe_install_linux_packages() {
    local pm
    pm="$(detect_package_manager)"

    if [[ "$pm" == "unknown" ]]; then
        log_warn "⚠️ No supported package manager detected. Install dependencies manually."
        return 1
    fi

    if is_immutable_linux_host; then
        log_warn "⚠️ Immutable/read-only Linux host detected. Skipping automatic package installation."
        log_warn "   Install missing packages via your host workflow (rpm-ostree/bootc layering, toolbox, or distrobox)."
        return 1
    fi

    if ! install_linux_packages "$pm" "$@"; then
        log_warn "⚠️ Package installation failed with $pm. You may need to install some dependencies manually."
        return 1
    fi

    return 0
}

resolve_download_tool() {
    if command_exists curl; then
        echo "curl"
    elif command_exists wget; then
        echo "wget"
    else
        return 1
    fi
}

download_file() {
    local url="$1"
    local output_path="$2"
    local downloader

    downloader="$(resolve_download_tool)" || return 1

    if [[ "$downloader" == "curl" ]]; then
        curl -fsSL "$url" -o "$output_path"
    else
        wget -q -O "$output_path" "$url"
    fi
}

venv_python_ready() {
    local python_bin="$1"
    [[ -x "$python_bin" ]] && "$python_bin" -V >/dev/null 2>&1
}

find_python_interpreter() {
    local candidate
    local resolved

    for candidate in "$@"; do
        [[ -z "${candidate:-}" ]] && continue

        if [[ "$candidate" == */* && -x "$candidate" ]]; then
            resolved="$candidate"
        elif command_exists "$candidate"; then
            resolved="$(command -v "$candidate")"
        else
            continue
        fi

        if "$resolved" - <<'PY' >/dev/null 2>&1
import sys
sys.exit(0 if sys.version_info >= (3, 10) else 1)
PY
        then
            echo "$resolved"
            return 0
        fi
    done

    return 1
}

python_version_string() {
    local python_bin="$1"
    "$python_bin" - <<'PY'
import sys
print(f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}")
PY
}

stemgen_env_ready() {
    venv_python_ready "$VENV_STEMGEN/bin/python" || return 1
    [[ -x "$VENV_STEMGEN/bin/stemgen" ]] || return 1

    "$VENV_STEMGEN/bin/python" - <<'PY' >/dev/null 2>&1
import importlib
for module in ("librosa", "mutagen", "torch"):
    importlib.import_module(module)
PY
}

tidal_env_ready() {
    venv_python_ready "$VENV_TIDAL/bin/python" || return 1
    [[ -x "$VENV_TIDAL/bin/tidal-dl-ng" ]] || return 1

    "$VENV_TIDAL/bin/python" - <<'PY' >/dev/null 2>&1
import tidal_dl_ng.cli
PY
}

ensure_system_prerequisites() {
    local missing=()
    local packages=()
    local item

    command_exists git || missing+=(git)
    command_exists tar || missing+=(tar)
    command_exists ffmpeg || missing+=(ffmpeg)
    command_exists ffprobe || missing+=(ffmpeg)
    if ! command_exists curl && ! command_exists wget; then
        missing+=(download-tool)
    fi
    if ! command_exists python3 && ! command_exists python; then
        missing+=(python3)
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_info "📦 Installing missing Linux packages: ${missing[*]}"

        case "$(detect_package_manager)" in
            apt)
                for item in "${missing[@]}"; do
                    case "$item" in
                        git) packages+=(git) ;;
                        tar) packages+=(tar) ;;
                        ffmpeg) packages+=(ffmpeg) ;;
                        download-tool) packages+=(curl wget) ;;
                        python3) packages+=(python3 python3-venv python3-pip) ;;
                    esac
                done
                ;;
            dnf)
                for item in "${missing[@]}"; do
                    case "$item" in
                        git) packages+=(git) ;;
                        tar) packages+=(tar) ;;
                        ffmpeg) packages+=(ffmpeg) ;;
                        download-tool) packages+=(curl wget) ;;
                        python3) packages+=(python3 python3-pip) ;;
                    esac
                done
                ;;
            pacman)
                for item in "${missing[@]}"; do
                    case "$item" in
                        git) packages+=(git) ;;
                        tar) packages+=(tar) ;;
                        ffmpeg) packages+=(ffmpeg) ;;
                        download-tool) packages+=(curl wget) ;;
                        python3) packages+=(python python-pip) ;;
                    esac
                done
                ;;
            zypper)
                for item in "${missing[@]}"; do
                    case "$item" in
                        git) packages+=(git) ;;
                        tar) packages+=(tar) ;;
                        ffmpeg) packages+=(ffmpeg) ;;
                        download-tool) packages+=(curl wget) ;;
                        python3) packages+=(python3 python3-pip) ;;
                    esac
                done
                ;;
        esac

        [[ ${#packages[@]} -gt 0 ]] && maybe_install_linux_packages "${packages[@]}"
    fi

    command_exists ffmpeg || die "ffmpeg is required. Install it and rerun DJ_Factory."
    command_exists ffprobe || die "ffprobe is required. Install it and rerun DJ_Factory."
    command_exists git || die "git is required. Install it and rerun DJ_Factory."
    command_exists tar || die "tar is required. Install it and rerun DJ_Factory."
    if ! command_exists curl && ! command_exists wget; then
        die "Need curl or wget to download dependencies."
    fi
}

ensure_optional_python_toolchains() {
    local packages=()
    local pm

    pm="$(detect_package_manager)"
    case "$pm" in
        apt)
            packages=(python3.11 python3.11-venv python3.11-dev python3.12 python3.12-venv python3.12-dev)
            ;;
        dnf)
            packages=(python3.11 python3.11-devel python3.12 python3.12-devel)
            ;;
        zypper)
            packages=(python311 python311-pip python312 python312-pip)
            ;;
        *)
            packages=()
            ;;
    esac

    if [[ ${#packages[@]} -gt 0 ]]; then
        maybe_install_linux_packages "${packages[@]}" || true
    fi
}

prepare_python_selection() {
    BOOTSTRAP_PYTHON="$(find_python_interpreter "${BOOTSTRAP_PYTHON:-}" python3 python)" || \
        die "Could not find a usable Python interpreter (>= 3.10)."

    STEMGEN_BUILD_PYTHON="$(find_python_interpreter "${STEMGEN_PYTHON:-}" python3.11 python3.10 python3)" || \
        die "Could not find Python for Stemgen. Install python3.11 or set STEMGEN_PYTHON=/path/to/python3.11."

    TIDAL_BUILD_PYTHON="$(find_python_interpreter "${TIDAL_PYTHON:-}" python3.12 python3.11 python3)" || \
        die "Could not find Python for Tidal. Install python3.12 or set TIDAL_PYTHON=/path/to/python."

    export BOOTSTRAP_PYTHON STEMGEN_BUILD_PYTHON TIDAL_BUILD_PYTHON

    local stemgen_version
    stemgen_version="$(python_version_string "$STEMGEN_BUILD_PYTHON")"
    if [[ "$stemgen_version" != 3.11.* ]]; then
        log_warn "⚠️ Stemgen is being built with Python $stemgen_version. Python 3.11 is preferred."
    else
        log_info "🐍 Stemgen will use Python $stemgen_version"
    fi

    local tidal_version
    tidal_version="$(python_version_string "$TIDAL_BUILD_PYTHON")"
    log_info "🐍 Tidal environment will use Python $tidal_version"
}

resolve_runtime_binaries() {
    FFMPEG_BIN="${FFMPEG_BIN:-$(command -v ffmpeg)}"
    FFPROBE_BIN="${FFPROBE_BIN:-$(command -v ffprobe)}"

    [[ -x "$FFMPEG_BIN" ]] || die "Resolved ffmpeg path is not executable: $FFMPEG_BIN"
    [[ -x "$FFPROBE_BIN" ]] || die "Resolved ffprobe path is not executable: $FFPROBE_BIN"

    export FFMPEG_BIN FFPROBE_BIN
}

install_onetagger() {
    if [[ -x "$BIN_DIR/onetagger-cli" ]]; then
        return 0
    fi

    log_info "📦 Installing OneTagger into $BIN_DIR"

    local latest_url
    latest_url="$("$BOOTSTRAP_PYTHON" "$SCRIPT_DIR/get_latest_onetagger.py" 2>/dev/null || true)"
    if [[ -z "$latest_url" ]]; then
        latest_url="https://github.com/Marekkon5/onetagger/releases/download/1.7.0/OneTagger-linux-cli.tar.gz"
    fi

    local temp_dir
    temp_dir="$(mktemp -d "$TMP_DIR/onetagger.XXXXXX")" || die "Failed to create temporary directory for OneTagger."

    if ! download_file "$latest_url" "$temp_dir/onetagger.tar.gz"; then
        rm -rf "$temp_dir"
        die "Failed to download OneTagger from $latest_url"
    fi

    if ! tar -xzf "$temp_dir/onetagger.tar.gz" -C "$temp_dir"; then
        rm -rf "$temp_dir"
        die "Failed to extract OneTagger archive."
    fi

    local extracted_bin
    extracted_bin="$(find "$temp_dir" -type f \( -name 'onetagger-cli' -o -name 'OneTagger*' \) -perm /111 | head -n 1)"
    if [[ -z "$extracted_bin" ]]; then
        extracted_bin="$(find "$temp_dir" -type f -perm /111 | head -n 1)"
    fi

    [[ -n "$extracted_bin" ]] || {
        rm -rf "$temp_dir"
        die "Could not find OneTagger executable inside archive."
    }

    mv -f "$extracted_bin" "$BIN_DIR/onetagger-cli"
    chmod +x "$BIN_DIR/onetagger-cli"
    rm -rf "$temp_dir"
}

patch_stemgen_cleanup_bug() {
    local stemgen_cli

    stemgen_cli="$("$VENV_STEMGEN/bin/python" - <<'PY'
import os
import site
import sysconfig
candidates = []
for path in site.getsitepackages():
    candidates.append(os.path.join(path, "stemgen", "cli.py"))
platlib = sysconfig.get_paths().get("platlib")
if platlib:
    candidates.append(os.path.join(platlib, "stemgen", "cli.py"))
for candidate in candidates:
    if os.path.isfile(candidate):
        print(candidate)
        break
PY
)"

    if [[ -n "$stemgen_cli" && -f "$stemgen_cli" ]]; then
        if grep -q 'os.remove(os.path.join(INPUT_DIR, file))' "$stemgen_cli"; then
            sed -i '/for file in os\.listdir(INPUT_DIR):/,/os\.remove(os\.path\.join(INPUT_DIR, file))/c\
    # PATCHED_DJ_FACTORY: removed .m4a deletion loop (destroyed previous stems)' "$stemgen_cli"
            log_info "🩹 Patched stemgen cleanup bug."
        fi
    fi
}

ensure_stemgen_env() {
    if stemgen_env_ready; then
        log_info "✅ Reusing existing Stemgen environment."
        patch_stemgen_cleanup_bug
        return 0
    fi

    if [[ -d "$VENV_STEMGEN" ]]; then
        log_warn "♻️ Rebuilding broken Stemgen environment in $VENV_STEMGEN"
        rm -rf "$VENV_STEMGEN"
    fi

    log_info "📦 Setting up Stemgen in repo-local venv..."

    "$STEMGEN_BUILD_PYTHON" -m venv "$VENV_STEMGEN" || die "Failed to create Stemgen virtualenv."
    "$VENV_STEMGEN/bin/python" -m pip install --upgrade pip setuptools wheel || die "Failed to upgrade pip for Stemgen."
    "$VENV_STEMGEN/bin/python" -m pip install torch==2.2.0 torchaudio==2.2.0 --index-url https://download.pytorch.org/whl/cpu || \
        die "Failed to install torch for Stemgen."
    "$VENV_STEMGEN/bin/python" -m pip install "numpy<2" "demucs<4.1" "librosa<0.11" "mutagen" "essentia" "git+https://github.com/axeldelafosse/stemgen" || \
        die "Failed to install Stemgen dependencies."

    patch_stemgen_cleanup_bug
    stemgen_env_ready || die "Stemgen environment did not validate after installation."
}

patch_tidal_imports() {
    local tidal_pkg_dir
    local cli_file
    local gui_file

    tidal_pkg_dir="$("$VENV_TIDAL/bin/python" - <<'PY'
import os
import site
import sysconfig

site_package_dirs = []
try:
    site_package_dirs.extend(site.getsitepackages())
except AttributeError:
    pass
site_package_dirs.append(sysconfig.get_paths().get("purelib", ""))
site_package_dirs.append(sysconfig.get_paths().get("platlib", ""))

for site_package_dir in site_package_dirs:
    if site_package_dir and os.path.isdir(os.path.join(site_package_dir, "tidal_dl_ng")):
        print(os.path.join(site_package_dir, "tidal_dl_ng"))
        break
PY
)" || tidal_pkg_dir=""
    [[ -d "$tidal_pkg_dir" ]] || return 0

    cli_file="$tidal_pkg_dir/cli.py"
    gui_file="$tidal_pkg_dir/gui.py"

    if [[ -f "$cli_file" ]]; then
        sed -i 's/^from config import HandlingApp$/from tidal_dl_ng.config import HandlingApp/' "$cli_file"
    fi

    if [[ -f "$gui_file" ]]; then
        sed -i 's/^from config import HandlingApp$/from tidal_dl_ng.config import HandlingApp/' "$gui_file"
    fi
}

ensure_tidal_env() {
    local tidal_pip_spec="${TIDAL_PIP_SPEC:-tidal-dl-ng[gui] @ https://github.com/r3ferrei/tidal-dl-ng-1/archive/refs/heads/master.zip}"

    if [[ -d "$VENV_TIDAL" ]]; then
        patch_tidal_imports
    fi

    if tidal_env_ready; then
        log_info "✅ Reusing existing Tidal environment."
        return 0
    fi

    if [[ -d "$VENV_TIDAL" ]]; then
        log_warn "♻️ Rebuilding broken Tidal environment in $VENV_TIDAL"
        rm -rf "$VENV_TIDAL"
    fi

    log_info "📦 Setting up Tidal in repo-local venv..."

    "$TIDAL_BUILD_PYTHON" -m venv "$VENV_TIDAL" || {
        log_warn "⚠️ Failed to create Tidal virtualenv. Tidal download will be unavailable."
        return 1
    }

    "$VENV_TIDAL/bin/python" -m pip install --upgrade pip setuptools wheel || {
        log_warn "⚠️ Failed to upgrade pip for Tidal. Tidal download will be unavailable."
        return 1
    }

    env -u GIT_ASKPASS -u SSH_ASKPASS -u GCM_INTERACTIVE -u GH_TOKEN \
        GIT_TERMINAL_PROMPT=0 \
        "$VENV_TIDAL/bin/python" -m pip install "$tidal_pip_spec" || {
        log_warn "⚠️ Failed to install tidal-dl-ng. Tidal download will be unavailable."
        log_warn "   You can override the source with TIDAL_PIP_SPEC='<package or URL>'."
        return 1
    }

    patch_tidal_imports

    if ! tidal_env_ready; then
        log_warn "⚠️ Tidal environment did not validate after installation. Tidal download will be unavailable."
        return 1
    fi

    return 0
}

setup_environment() {
    log_info "🔧 Checking Environment & Dependencies..."

    mkdir -p "$BIN_DIR" "$SCRIPT_DIR" "$DEFAULT_INPUT_DIR" "$DEFAULT_OUTPUT_DIR" \
        "$CACHE_DIR" "$STATE_DIR" "$LOG_DIR" "$TMP_DIR"

    ensure_system_prerequisites
    ensure_optional_python_toolchains
    prepare_python_selection
    resolve_runtime_binaries
    install_onetagger
    ensure_stemgen_env
    ensure_tidal_env || true

    export PYTHON_PROC="$VENV_STEMGEN/bin/python"
    if [[ -x "$VENV_TIDAL/bin/tidal-dl-ng" ]]; then
        export TIDAL_BIN="$VENV_TIDAL/bin/tidal-dl-ng"
    else
        export TIDAL_BIN=""
    fi
    export STEMGEN_BIN="$VENV_STEMGEN/bin/stemgen"

    printf 'completed %s\n' "$(date -Is)" > "$SETUP_MARKER"
    log_info "✅ Environment ready."
}

desktop_exec_escape() {
    local value="$1"

    # Exec is a quoted desktop-entry argument. Escape characters that have
    # meaning inside a quoted Exec value before writing the launcher. A literal
    # percent must be doubled because desktop entries reserve percent codes.
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//%/%%}"
    printf '%s' "$value"
}

create_desktop_shortcut() {
    local desktop_file
    local exec_path
    local escaped_exec_path
    local icon_path

    desktop_file="${XDG_DATA_HOME:-$HOME/.local/share}/applications/DJ_Factory.desktop"
    exec_path="$ROOT_DIR/main.sh"
    escaped_exec_path="$(desktop_exec_escape "$exec_path")"
    icon_path="$ROOT_DIR/icon.png"

    mkdir -p "$(dirname "$desktop_file")"
    [[ -f "$icon_path" ]] || icon_path="utilities-terminal"

    cat > "$desktop_file" <<EOF
[Desktop Entry]
Type=Application
Name=DJ_Factory
Comment=Automated Audio Processing Tool
Exec="$escaped_exec_path"
Icon=$icon_path
Terminal=true
Categories=Audio;Utility;
EOF

    chmod +x "$desktop_file"
}
