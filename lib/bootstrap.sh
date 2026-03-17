#!/usr/bin/env bash
# lib/bootstrap.sh

# =================================================
# ENVIRONMENT SETUP
# =================================================
setup_environment() {
    echo -e "${CYAN}🔧 Checking Environment & Dependencies...${NC}"

    # 1. DIRECTORY INITIALIZATION
    # ---------------------------------------------
    # Ensure all critical folders exist before we start
    mkdir -p "$BIN_DIR" "$SCRIPT_DIR" "$DEFAULT_INPUT_DIR" "$DEFAULT_OUTPUT_DIR"


    # 2. SYSTEM LIBRARIES (HYBRID SETUP)
    # ---------------------------------------------
    # We check for Python 3.12 specifically. If missing, we install the PPA.
    if ! command -v python3.12 &> /dev/null; then
        echo -e "${RED}❌ Installing Python 3.12 & System Libs...${NC}"

        sudo apt-get update
        sudo apt-get install -y software-properties-common
        sudo add-apt-repository ppa:deadsnakes/ppa -y
        sudo apt-get update

        # Install Audio Tools (ffmpeg, sox) and Python Build deps
        sudo apt-get install -y ffmpeg sox libsox-fmt-all git wget curl libjpeg62 \
            python3-venv python3-dev build-essential \
            python3.12 python3.12-venv python3.12-dev
    fi


    # 3. ONETAGGER INSTALLATION
    # ---------------------------------------------
    # Checks if the binary exists; if not, fetches the latest version.
    if [ ! -f "$BIN_DIR/onetagger-cli" ]; then
        echo -e "${CYAN}📦 Installing OneTagger...${NC}"

        # Try to get dynamic link, fall back to hardcoded 1.7.0 if script fails
        LATEST_URL=$(python3 "$SCRIPT_DIR/get_latest_onetagger.py" 2>/dev/null)
        if [ -z "$LATEST_URL" ]; then
             LATEST_URL="https://github.com/Marekkon5/onetagger/releases/download/1.7.0/OneTagger-linux-cli.tar.gz"
        fi

        # Download and Extract
        TEMP_DIR=$(mktemp -d)
        wget -q -O "$TEMP_DIR/onetagger.tar.gz" "$LATEST_URL"
        tar -xzf "$TEMP_DIR/onetagger.tar.gz" -C "$TEMP_DIR"

        # Find the binary inside the extracted folder (regardless of folder name)
        EXTRACTED_BIN=$(find "$TEMP_DIR" -type f -executable | head -n 1)
        if [ -n "$EXTRACTED_BIN" ]; then
            mv "$EXTRACTED_BIN" "$BIN_DIR/onetagger-cli"
            chmod +x "$BIN_DIR/onetagger-cli"
        fi
        rm -rf "$TEMP_DIR"
    fi


    # 4. VIRTUAL ENVIRONMENTS
    # ---------------------------------------------

    # --- A. STEMGEN (Python 3.10 / Default System Python) ---
    # "THE IRON LOCK FIX": Specific versions to prevent dependency hell
    if [ ! -d "$VENV_STEMGEN" ]; then
        echo -e "${CYAN}📦 Setting up Stemgen (Solver Mode)...${NC}"

        python3 -m venv "$VENV_STEMGEN"
        source "$VENV_STEMGEN/bin/activate"
        pip install --upgrade pip

        # 1. Install CPU-only Torch first (lighter, faster)
        pip install torch==2.2.0 torchaudio==2.2.0 --index-url https://download.pytorch.org/whl/cpu

        # 2. Install everything else in ONE go to force pip to solve versions correctly
        # pinning numpy<2 prevents the recent API breakage in audio libs
        pip install "numpy<2" "demucs<4.1" "librosa<0.11" "mutagen" "essentia" "git+https://github.com/axeldelafosse/stemgen"

        # PATCH: fix stemgen bug where clean_dir() deletes all .m4a from input dir
        # This nukes previously-generated stems when input dir == output dir.
        local stemgen_cli="$VENV_STEMGEN/lib/python3.11/site-packages/stemgen/cli.py"
        if [ -f "$stemgen_cli" ]; then
            sed -i '/for file in os\.listdir(INPUT_DIR):/,/os\.remove(os\.path\.join(INPUT_DIR, file))/c\
    # PATCHED: removed .m4a deletion loop (destroyed previous stems)' "$stemgen_cli"
        fi

        deactivate
    fi

    # --- B. TIDAL-DL (Python 3.12) ---
    # Uses the NG fork for better Hi-Res support
    if [ ! -d "$VENV_TIDAL" ]; then
        echo -e "${CYAN}📦 Setting up Tidal (Py3.12)...${NC}"

        python3.12 -m venv "$VENV_TIDAL"
        source "$VENV_TIDAL/bin/activate"
        pip install --upgrade pip

        # Install from specific git fork branch
        pip install 'git+https://github.com/nilleiz/tidal_dl_ng.git#egg=tidal-dl-ng[gui]'

        deactivate
    fi


    # 5. EXPORT BINARIES
    # ---------------------------------------------
    # Make these paths available to the rest of the pipeline
    export PYTHON_PROC="$VENV_STEMGEN/bin/python3"
    export TIDAL_BIN="$VENV_TIDAL/bin/tidal-dl-ng"
    export STEMGEN_BIN="$VENV_STEMGEN/bin/stemgen"
    export FFMPEG_BIN="/usr/bin/ffmpeg"
    export FFPROBE_BIN="/usr/bin/ffprobe"
}

# =================================================
# DESKTOP INTEGRATION
# =================================================
create_desktop_shortcut() {
    DESKTOP_FILE="$HOME/.local/share/applications/DJ_Factory.desktop"
    EXEC_PATH="$ROOT_DIR/main.sh"

    # Fallback icon if custom png is missing
    ICON_PATH="$ROOT_DIR/icon.png"
    if [ ! -f "$ICON_PATH" ]; then ICON_PATH="utilities-terminal"; fi

    cat << EOF > "$DESKTOP_FILE"
[Desktop Entry]
Type=Application
Name=DJ_Factory
Comment=Automated Audio Processing Tool
Exec="$EXEC_PATH"
Icon="$ICON_PATH"
Terminal=true
Categories=Audio;Utility;
EOF
    chmod +x "$DESKTOP_FILE"
}
