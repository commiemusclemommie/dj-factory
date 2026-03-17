#!/usr/bin/env bash
# lib/config.sh

# =================================================
# 1. CONTAINER SETTINGS
# =================================================
BOX_NAME="Ustembox"
BOX_IMAGE="ubuntu:22.04"

# =================================================
# 2. DYNAMIC SYSTEM DETECTION
# =================================================
# Detect the real "Music" folder (handles different languages/OS setups)
if command -v xdg-user-dir &> /dev/null; then
    SYSTEM_MUSIC_DIR=$(xdg-user-dir MUSIC)
else
    SYSTEM_MUSIC_DIR="$HOME/Music"
fi

# =================================================
# 3. DEFAULT USER PATHS (SUGGESTIONS)
# =================================================
# These are loaded by the Menu as the starting values.
# The user can edit them in the TUI (Terminal User Interface).

# Suggestion: Where raw files/downloads usually start
DEFAULT_INPUT_DIR="$SYSTEM_MUSIC_DIR/Input_Folder"

# Suggestion: Where the Tidal Downloader dumps files (if used)
DEFAULT_TIDAL_DIR="$DEFAULT_INPUT_DIR"

# Suggestion: Where the finished pipeline results go
DEFAULT_OUTPUT_DIR="$SYSTEM_MUSIC_DIR/Finalized_Pipeline"

# Ensure these folders exist so we never crash on a "missing directory" error
mkdir -p "$SYSTEM_MUSIC_DIR"
mkdir -p "$DEFAULT_INPUT_DIR"
mkdir -p "$DEFAULT_TIDAL_DIR"
mkdir -p "$DEFAULT_OUTPUT_DIR"

# =================================================
# 4. INTERNAL APPLICATION PATHS
# =================================================
# These are relative to where you installed the script.
# We use BASH_SOURCE to locate *this* file (config.sh) inside /lib/
# and step back one level to find the Project Root.

LIB_DIR=$(dirname "$(realpath "${BASH_SOURCE[0]}")")
ROOT_DIR=$(dirname "$LIB_DIR")

SCRIPT_DIR="$ROOT_DIR/scripts"
BIN_DIR="$ROOT_DIR/bin"
VENV_STEMGEN="$ROOT_DIR/stemgen-venv"
VENV_TIDAL="$ROOT_DIR/tidal-venv"

# Data / Config Files
TIDAL_URL_FILE="$SCRIPT_DIR/tidal_playlist.txt"
ONETAGGER_CONF="$SCRIPT_DIR/onetagger.json"

# =================================================
# 5. AUDIO & PROCESSING RULES
# =================================================
TARGET_I="-14"          # Target integrated loudness (LUFS)
STEM_MODEL="htdemucs_ft"  # Demucs model for stem separation
STEM_DEVICE="cpu"       # cpu / cuda / mps

# Performance Tuning (Leave 1 core free for the OS)
CORES=$(nproc)
THREADS=$((CORES - 1))
if [ "$THREADS" -lt 1 ]; then THREADS=1; fi

# =================================================
# 6. VISUAL STYLES
# =================================================
GREEN='\033[0;32m'
CYAN='\033[0;36m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# =================================================
# 7. EXPORTS
# =================================================
# We export these so Python scripts or sub-shells can see them.
# Note: We do NOT export DEFAULT_INPUT_DIR because the Menu will determine
# the actual "CURRENT_INPUT" and pass that instead.

export ROOT_DIR SCRIPT_DIR BIN_DIR ONETAGGER_CONF
export TARGET_I STEM_MODEL STEM_DEVICE THREADS
