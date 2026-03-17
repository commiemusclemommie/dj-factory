#!/usr/bin/env bash
# lib/processing.sh

# ==============================================
# HELPERS
# ==============================================
is_non_aiff_source() {
    local ext="${1##*.}"
    ext="${ext,,}"  # lowercase
    [[ "$ext" =~ ^(mp3|m4a|alac|wav|wave)$ ]]
}

# ── Measure integrated loudness (LUFS) via loudnorm in measure-only mode ──
# Returns the linear gain in dB needed to reach TARGET_I.
# Falls back to 0 dB (no change) if measurement fails.
measure_gain_db() {
    local input_file="$1"
    local json
    json=$("$FFMPEG_BIN" -i "$input_file" -vn -filter:a 'loudnorm=print_format=json' \
           -f null null -hide_banner 2>&1 | awk '/^\{/,/^\}/ {print}')

    local input_i
    input_i=$(echo "$json" | grep '"input_i"' | awk -F': "' '{print $2}' | awk -F'"' '{print $1}')

    if [[ -z "$input_i" || "$input_i" == "-inf" ]]; then
        echo "0"
        return 1
    fi

    python3 -c "print(round(float('$TARGET_I') - float('$input_i'), 2))" 2>/dev/null || echo "0"
}

# ── Detect bit depth and sample rate via ffprobe ──
get_audio_info() {
    local input_file="$1"
    local ext="${input_file##*.}"
    ext="${ext,,}"

    # Bit depth: try bits_per_raw_sample first (works for FLAC), then bits_per_sample
    local bd
    bd=$("$FFPROBE_BIN" -v error -select_streams a:0 \
         -show_entries stream=bits_per_raw_sample \
         -of default=noprint_wrappers=1:nokey=1 "$input_file" 2>/dev/null)
    [[ -z "$bd" || "$bd" == "0" || "$bd" == "N/A" ]] && \
        bd=$("$FFPROBE_BIN" -v error -select_streams a:0 \
             -show_entries stream=bits_per_sample \
             -of default=noprint_wrappers=1:nokey=1 "$input_file" 2>/dev/null)
    [[ -z "$bd" || "$bd" == "0" || "$bd" == "N/A" ]] && bd=16

    local sr
    sr=$("$FFPROBE_BIN" -v error -select_streams a:0 \
         -show_entries stream=sample_rate \
         -of default=noprint_wrappers=1:nokey=1 "$input_file" 2>/dev/null)
    [[ -z "$sr" || "$sr" == "N/A" ]] && sr=44100

    # Export for caller
    DETECTED_BD="$bd"
    DETECTED_SR="$sr"
}

process_stem_normalization() {
    local input_file="$1"
    local output_dir="$2"
    local filename=$(basename "$input_file")
    local target_path="$output_dir/$filename"

    local gain_diff
    gain_diff=$(measure_gain_db "$input_file")

    if [[ "$gain_diff" == "0" ]]; then
        echo -e "    🔊 Stem: loudness OK (no adjustment needed)" >&2
    else
        echo -e "    🔊 Normalizing Stem: ${gain_diff} dB" >&2
    fi

    "$FFMPEG_BIN" -nostdin -i "$input_file" -af "volume=${gain_diff}dB" \
        -c:a alac -c:v copy -map 0 \
        -disposition:v:0 attached_pic -map_metadata 0 \
        -y -hide_banner -loglevel error "$target_path"

    echo "$target_path"
}

process_audio_specs() {
    local input_file="$1"
    local output_dir="$2"
    local normalize="${3:-1}"  # 1=normalize, 0=convert only
    local filename=$(basename "$input_file")
    local base_name="${filename%.*}"
    local ext="${filename##*.}"
    ext="${ext,,}"
    local target_path="$output_dir/$base_name.aiff"

    # --- Loudness measurement (only if normalizing) ---
    local gain_diff="0"
    if [[ "$normalize" -eq 1 ]]; then
        gain_diff=$(measure_gain_db "$input_file")
    fi

    # --- Detect format ---
    get_audio_info "$input_file"

    # --- Output codec ---
    local out_codec="pcm_s16be"
    if [[ "$ext" != "mp3" ]]; then
        case "$DETECTED_BD" in
            24|32) out_codec="pcm_s24be" ;;
            *)     out_codec="pcm_s16be" ;;
        esac
    fi

    # --- Output sample rate (clamp to 44.1–48kHz range) ---
    local sr_args=""
    if [[ "$ext" == "mp3" ]]; then
        sr_args="-ar 44100"
    elif (( DETECTED_SR < 44100 )); then
        sr_args="-ar 44100"
    elif (( DETECTED_SR > 48000 )); then
        sr_args="-ar 48000"
    fi

    if [[ "$gain_diff" != "0" ]]; then
        echo -e "    🔊 → AIFF ${out_codec##*_} ${DETECTED_SR}Hz ${gain_diff}dB" >&2
    else
        echo -e "    🔄 → AIFF ${out_codec##*_} ${DETECTED_SR}Hz" >&2
    fi

    # --- Build filter chain ---
    local af_args=""
    [[ "$gain_diff" != "0" ]] && af_args="-af volume=${gain_diff}dB"

    # --- Convert ---
    "$FFMPEG_BIN" -nostdin -i "$input_file" \
        $af_args $sr_args -c:a "$out_codec" \
        -map 0:a:0 -map 0:v? -c:v copy \
        -disposition:v:0 attached_pic \
        -map_metadata 0 -write_id3v2 1 \
        -y -hide_banner -loglevel error "$target_path"

    if [[ ! -f "$target_path" ]]; then
        echo -e "    ❌ Conversion failed for: $filename" >&2
        return 1
    fi

    echo "$target_path"
}

# ==============================================
# MENU
# ==============================================
show_menu() {
    CURRENT_INPUT="$DEFAULT_INPUT_DIR"
    CURRENT_OUTPUT="$DEFAULT_OUTPUT_DIR"
    SELECTIONS=(1 1 1 1 1)
    LABELS=("🌊 Tidal Download" "🏷️  OneTagger" "🔊 Normalize → AIFF" "🔨 Stem Separation" "🎹 Detune Detection")
    DESCRIPTIONS=(
        "Download from Tidal playlist/album"
        "Auto-tag genre from online databases"
        "Normalize to ${TARGET_I} LUFS, convert to AIFF"
        "Create NI stem files (${STEM_MODEL})"
        "Detect and tag pitch deviations"
    )

    while true; do
        clear
        echo ""
        echo -e "  ${CYAN}╔══════════════════════════════════════╗${NC}"
        echo -e "  ${CYAN}║         🎛️  DJ FACTORY              ║${NC}"
        echo -e "  ${CYAN}╚══════════════════════════════════════╝${NC}"
        echo ""
        echo -e "  ${YELLOW}INPUT ${NC} $CURRENT_INPUT"
        echo -e "  ${YELLOW}OUTPUT${NC} $CURRENT_OUTPUT"
        echo ""
        echo -e "  ─────── Pipeline Steps ───────"

        for i in "${!LABELS[@]}"; do
            if [[ ${SELECTIONS[$i]} -eq 1 ]]; then
                echo -e "  ${GREEN}[$i] ■${NC} ${LABELS[$i]}"
            else
                echo -e "  [$i] □ ${LABELS[$i]}"
            fi
        done

        # Count input files
        local file_count=0
        if [[ -d "$CURRENT_INPUT" ]]; then
            file_count=$(find "$CURRENT_INPUT" -maxdepth 1 -type f \
                \( -iname "*.flac" -o -iname "*.wav" -o -iname "*.aiff" -o -iname "*.m4a" -o -iname "*.mp3" \) 2>/dev/null | wc -l)
        fi

        echo ""
        echo -e "  ─────── Actions ─────────────"
        echo -e "  ${GREEN}[R]${NC} Run Pipeline  (${file_count} files)"
        echo -e "  [I] Edit Input   [O] Edit Output"
        echo -e "  [Q] Quit"
        echo ""

        read -p "  > " choice
        case $choice in
            [0-4]) SELECTIONS[$choice]=$((1-SELECTIONS[$choice])) ;;
            i|I) read -e -i "$CURRENT_INPUT" -p "  Input: " new_in
                 [[ -n "$new_in" ]] && CURRENT_INPUT="$new_in" ;;
            o|O) read -e -i "$CURRENT_OUTPUT" -p "  Output: " new_out
                 [[ -n "$new_out" ]] && CURRENT_OUTPUT="$new_out" ;;
            r|R) return 0 ;;
            q|Q) echo ""; exit 0 ;;
        esac
    done
}

# ==============================================
# PIPELINE
# ==============================================
run_pipeline() {
    mkdir -p "$CURRENT_OUTPUT"

    # --- STEP 0: TIDAL DOWNLOADER ---
    if [[ ${SELECTIONS[0]} -eq 1 ]]; then
        echo -e "${YELLOW}🌊 Tidal Download Setup${NC}"
        "$PYTHON_PROC" "$SCRIPT_DIR/update_tidal_config.py" "$CURRENT_INPUT"

        if ! "$TIDAL_BIN" cfg &> /dev/null; then
             echo -e "${RED}⚠️  Login Required...${NC}"
             "$TIDAL_BIN" login
        fi

        if [ -f "$TIDAL_URL_FILE" ]; then
            SAVED_URL=$(cat "$TIDAL_URL_FILE")
            echo -e "    📂 Found Saved Playlist: ${CYAN}$SAVED_URL${NC}"
            read -p "    Use this? [Y/n]: " use_saved
            [[ "$use_saved" =~ ^[Nn]$ ]] && read -p "    Paste NEW Tidal URL: " TIDAL_LINK || TIDAL_LINK="$SAVED_URL"
        else
            read -p "    Paste Tidal URL: " TIDAL_LINK
        fi

        [[ -n "$TIDAL_LINK" ]] && echo "$TIDAL_LINK" > "$TIDAL_URL_FILE" && "$TIDAL_BIN" dl "$TIDAL_LINK"
    fi

    echo -e "\n${GREEN}🚀 PROCESSING BATCH...${NC}"

    mapfile -d $'\0' -t FILE_LIST < <(find "$CURRENT_INPUT" -maxdepth 1 -type f \
        \( -iname "*.flac" -o -iname "*.wav" -o -iname "*.aiff" -o -iname "*.m4a" -o -iname "*.mp3" \) -print0)

    for raw_file in "${FILE_LIST[@]}"; do
        [[ -z "$raw_file" ]] && continue

        STEM_CREATED=0
        is_temp_file=0
        filename=$(basename "$raw_file")
        base_name="${filename%.*}"
        current_source=$(realpath "$raw_file")
        IS_STEM=0
        [[ "$filename" == *".stem.m4a" ]] && IS_STEM=1

        echo "---------------------------------------------------"
        echo -e "🎵 ${CYAN}$filename${NC}"

        # --- STEP A: ONETAGGER ---
        if [[ ${SELECTIONS[1]} -eq 1 ]]; then
            echo "    🏷️  Running OneTagger..."
            timeout 2m "$BIN_DIR/onetagger-cli" autotagger --config "$ONETAGGER_CONF" --path "$current_source"
        fi

        # --- STEP B: NORMALIZE & CONVERT ---
        #
        # When stems are enabled, we always write the intermediate file to
        # /tmp so stemgen's cleanup never touches the output folder.
        # Stemgen's clean_dir() deletes ALL .m4a files from its input
        # directory — writing intermediates to /tmp avoids that.

        STEMS_ENABLED=0
        [[ ${SELECTIONS[3]} -eq 1 && "$IS_STEM" -eq 0 ]] && STEMS_ENABLED=1

        if [[ "$IS_STEM" -eq 1 ]]; then
            # Existing stem file — only normalize if selected
            if [[ ${SELECTIONS[2]} -eq 1 ]]; then
                echo "    🔊 Normalizing Stem..."
                processed_file=$(process_stem_normalization "$current_source" "$CURRENT_OUTPUT")
            else
                cp "$current_source" "$CURRENT_OUTPUT/"
                processed_file="$CURRENT_OUTPUT/$filename"
            fi
        elif [[ ${SELECTIONS[2]} -eq 1 ]] || is_non_aiff_source "$current_source"; then
            # Needs conversion and/or normalization
            local norm_flag=${SELECTIONS[2]}
            if [[ "$STEMS_ENABLED" -eq 1 ]]; then
                # Write to /tmp — stemgen will use this, then we copy final to output
                processed_file=$(process_audio_specs "$current_source" "/tmp" "$norm_flag")
                is_temp_file=1
            else
                processed_file=$(process_audio_specs "$current_source" "$CURRENT_OUTPUT" "$norm_flag")
            fi
        else
            # Already AIFF/FLAC and normalization not selected
            if [[ "$STEMS_ENABLED" -eq 1 ]]; then
                # Copy to /tmp for stemgen safety
                cp "$current_source" "/tmp/$filename"
                processed_file="/tmp/$filename"
                is_temp_file=1
            else
                cp "$current_source" "$CURRENT_OUTPUT/"
                processed_file="$CURRENT_OUTPUT/$filename"
            fi
        fi

        # --- STEP C: STEMGEN ---
        STEM_FILE=""
        if [[ "$STEMS_ENABLED" -eq 1 ]]; then
            echo "    🔨 Handing off to Stemgen..."

            # Note: stemgen's clean_dir() has been patched (see bootstrap.sh)
            # to not delete .m4a files from the input directory. The input file
            # is also in /tmp as an extra safety measure.
            local stem_count_before
            stem_count_before=$(find "$CURRENT_OUTPUT" -maxdepth 1 -name "*.stem.m4a" 2>/dev/null | wc -l)

            "$STEMGEN_BIN" -i "$processed_file" -n "$STEM_MODEL" --device "$STEM_DEVICE" -o "$CURRENT_OUTPUT/" < /dev/null

            # Find newly created stem (anything that wasn't there before)
            local stem_count_after
            stem_count_after=$(find "$CURRENT_OUTPUT" -maxdepth 1 -name "*.stem.m4a" 2>/dev/null | wc -l)

            CREATED_STEM=""
            if [[ "$stem_count_after" -gt "$stem_count_before" ]]; then
                CREATED_STEM=$(find "$CURRENT_OUTPUT" -maxdepth 1 -name "*.stem.m4a" -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)
            fi

            if [[ -n "$CREATED_STEM" ]]; then
                # Rename to match original filename (fixes Unicode stripping bug)
                EXPECTED_STEM="$CURRENT_OUTPUT/${base_name}.stem.m4a"
                if [[ "$CREATED_STEM" != "$EXPECTED_STEM" ]]; then
                    mv "$CREATED_STEM" "$EXPECTED_STEM" 2>/dev/null && STEM_FILE="$EXPECTED_STEM" || STEM_FILE="$CREATED_STEM"
                else
                    STEM_FILE="$CREATED_STEM"
                fi
                STEM_CREATED=1
                echo "    ✅ Stem Created: $(basename "$STEM_FILE")"
            else
                echo "    ⚠️  Stem file not found!"
            fi

            # Now copy the processed AIFF to its final location (was in /tmp)
            if [[ "$is_temp_file" -eq 1 && -f "$processed_file" ]]; then
                cp "$processed_file" "$CURRENT_OUTPUT/"
                final_file="$CURRENT_OUTPUT/$(basename "$processed_file")"
            fi
        fi

        # Determine the final output file path for tagging
        if [[ -n "$final_file" && -f "$final_file" ]]; then
            output_file="$final_file"
        else
            output_file="$processed_file"
        fi

        # --- STEP D: DETUNE ---
        DETUNE_TAG=""
        if [[ ${SELECTIONS[4]} -eq 1 ]]; then
            echo "    🎹 Checking Detune..."
            # Prefer stem file (cleaner signal), fall back to processed file
            CHECK_FILE="$output_file"
            [[ "$STEM_CREATED" -eq 1 && -f "$STEM_FILE" ]] && CHECK_FILE="$STEM_FILE"
            DETUNE_OUT=$("$PYTHON_PROC" "$SCRIPT_DIR/analyze_stems.py" "$CHECK_FILE" 2>&1 | tail -n 1)
            if [[ "$DETUNE_OUT" =~ ^[+-][0-9]+c$ ]]; then
                DETUNE_TAG="$DETUNE_OUT"
            fi
        fi

        # --- STEP E: TAGGING ---
        if [[ -n "$DETUNE_TAG" ]]; then
            "$PYTHON_PROC" "$SCRIPT_DIR/write_tag.py" "$output_file" "$DETUNE_TAG"
            [[ "$STEM_CREATED" -eq 1 && -f "$STEM_FILE" ]] && \
                "$PYTHON_PROC" "$SCRIPT_DIR/write_tag.py" "$STEM_FILE" "$DETUNE_TAG"
            echo "    🎹 Tagged: $DETUNE_TAG"
        fi

        # --- CLEANUP ---
        [[ "$is_temp_file" -eq 1 ]] && rm -f "$processed_file"
        unset final_file output_file

    done
}
