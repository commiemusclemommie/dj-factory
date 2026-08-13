#!/usr/bin/env bash
# lib/processing.sh

# ==============================================
# HELPERS
# ==============================================
is_non_aiff_source() {
    local ext="${1##*.}"
    ext="${ext,,}"
    [[ "$ext" =~ ^(mp3|m4a|alac|wav|wave)$ ]]
}

absolute_path() {
    local target="$1"
    readlink -f "$target" 2>/dev/null || printf '%s\n' "$target"
}

trim_whitespace() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s\n' "$value"
}

prompt_with_current() {
    local label="$1"
    local current="$2"
    local result=""

    echo -e "  ${YELLOW}Current $label:${NC} $current" >&2
    echo "  Press Enter to keep it, or edit/type a new value." >&2

    if [[ -t 0 && -t 1 ]]; then
        # -e/-i gives readline editing with the current value prefilled.
        read -e -r -i "$current" -p "  $label: " result
    else
        read -r -p "  $label [$current]: " result
        [[ -z "$result" ]] && result="$current"
    fi

    trim_whitespace "$result"
}

normalize_tidal_link() {
    local link
    link="$(trim_whitespace "$1")"
    [[ -z "$link" ]] && return 0

    # tidal-dl-ng is most reliable with /browse/ URLs. Shared playlist links are
    # commonly copied as https://tidal.com/playlist/<uuid>; normalize those.
    if [[ "$link" =~ tidal\.com/playlist/([0-9a-fA-F-]{36}) ]]; then
        printf 'https://tidal.com/browse/playlist/%s\n' "${BASH_REMATCH[1]}"
    elif [[ "$link" =~ tidal\.com/(track|album|playlist|video)/([^/?#[:space:]]+) ]]; then
        printf 'https://tidal.com/browse/%s/%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    else
        printf '%s\n' "$link"
    fi
}

audio_duration_seconds() {
    local input_file="$1"
    "$FFPROBE_BIN" -v error -show_entries format=duration \
        -of default=noprint_wrappers=1:nokey=1 "$input_file" 2>/dev/null | \
        awk '{printf "%.2f", $1}'
}

audio_duration_int() {
    local input_file="$1"
    local duration
    duration="$(audio_duration_seconds "$input_file")"
    [[ -z "$duration" ]] && duration=0
    awk -v d="$duration" 'BEGIN { printf "%d", d + 0.5 }'
}

safe_remove_stemgen_work() {
    local base_name="$1"
    local output_real
    local expected_dir
    local expected_stem

    # Stemgen caches/converts inside OUTPUT/base_name. If an earlier Tidal run
    # produced a 30-second preview, that stale work folder can make all future
    # stems 30 seconds even after the FLAC is redownloaded correctly.
    #
    # A filename such as ".m4a" has an empty stem. Never let that turn the
    # cleanup target into CURRENT_OUTPUT itself (or a parent/sibling path).
    if [[ -z "$base_name" || "$base_name" == "." || "$base_name" == ".." || "$base_name" == */* ]]; then
        echo "    ⚠️ Skipping unsafe Stemgen cleanup for empty/invalid basename." >&2
        return 0
    fi

    output_real="$(absolute_path "$CURRENT_OUTPUT")"
    [[ -d "$output_real" ]] || return 0
    expected_dir="$output_real/$base_name"
    expected_stem="$output_real/$base_name.stem.m4a"

    # Both targets must be direct children of the resolved output directory.
    [[ "$expected_dir" != "$output_real" && "$(dirname -- "$expected_dir")" == "$output_real" ]] || return 0
    if [[ -d "$expected_dir" ]] && ! rm -rf -- "$expected_dir"; then
        return 1
    fi
    if [[ -f "$expected_stem" ]] && ! rm -f -- "$expected_stem"; then
        return 1
    fi
    return 0
}

run_interruptible_command() {
    local pid
    local status

    # Keep external work in the worker's supervised process group. Creating a
    # new session here would let a descendant survive owner death and mutate
    # after the lock is released.
    "$@" < /dev/null &

    pid=$!
    ACTIVE_CHILD_PID="$pid"
    wait "$pid"
    status=$?
    export ACTIVE_CHILD_PID=""
    return "$status"
}

quarantine_short_tidal_previews() {
    local scan_dir="$1"
    local quarantine_dir="$scan_dir/_short_tidal_previews"
    local file
    local duration
    local moved=0

    [[ -d "$scan_dir" ]] || return 0

    while IFS= read -r -d '' file; do
        duration="$(audio_duration_int "$file")"
        if (( duration >= 25 && duration <= 35 )); then
            mkdir -p "$quarantine_dir"
            mv -f "$file" "$quarantine_dir/"
            echo -e "    ${YELLOW}⚠️ Quarantined likely 30-second Tidal preview: $(basename "$file")${NC}" >&2
            moved=$((moved + 1))
        fi
    done < <(
        find "$scan_dir" -maxdepth 1 -type f \
            \( -iname "*.flac" -o -iname "*.wav" -o -iname "*.aiff" -o -iname "*.m4a" -o -iname "*.mp3" \) -print0 2>/dev/null
    )

    if (( moved > 0 )); then
        echo -e "    ${YELLOW}⚠️ Moved ${moved} short preview file(s) to: $quarantine_dir${NC}" >&2
        echo -e "    ${YELLOW}   Re-run Tidal after confirming login/subscription; skip_existing is disabled so full files can replace previews.${NC}" >&2
    fi
}

safe_copy_to_dir() {
    local source_path="$1"
    local destination_dir="$2"
    local target_path
    local source_real
    local target_real

    target_path="$destination_dir/$(basename "$source_path")"
    mkdir -p "$destination_dir" || return 1

    source_real="$(absolute_path "$source_path")"
    target_real="$(absolute_path "$target_path")"

    if [[ "$source_real" == "$target_real" ]]; then
        echo "$target_path"
        return 0
    fi

    cp -f "$source_path" "$target_path" || return 1
    echo "$target_path"
}

create_file_work_dir() {
    local seed="$1"
    local safe_seed

    safe_seed="$(printf '%s' "$seed" | tr -cs '[:alnum:]._-' '_')"
    mktemp -d "$RUN_TMP_DIR/${safe_seed}.XXXXXX"
}

measure_gain_db() {
    local input_file="$1"
    local json
    local input_i
    local math_python="${PYTHON_PROC:-${BOOTSTRAP_PYTHON:-python3}}"

    json=$(
        "$FFMPEG_BIN" -i "$input_file" -vn -filter:a 'loudnorm=print_format=json' \
            -f null null -hide_banner 2>&1 | awk '/^\{/,/^\}/ {print}'
    )

    input_i=$(printf '%s\n' "$json" | grep '"input_i"' | head -n 1 | awk -F': "' '{print $2}' | awk -F'"' '{print $1}')

    if [[ -z "$input_i" || "$input_i" == "-inf" ]]; then
        echo "0"
        return 1
    fi

    "$math_python" -c "print(round(float('$TARGET_I') - float('$input_i'), 2))" 2>/dev/null || echo "0"
}

get_audio_info() {
    local input_file="$1"
    local bd
    local sr

    bd=$(
        "$FFPROBE_BIN" -v error -select_streams a:0 \
            -show_entries stream=bits_per_raw_sample \
            -of default=noprint_wrappers=1:nokey=1 "$input_file" 2>/dev/null
    )

    if [[ -z "$bd" || "$bd" == "0" || "$bd" == "N/A" ]]; then
        bd=$(
            "$FFPROBE_BIN" -v error -select_streams a:0 \
                -show_entries stream=bits_per_sample \
                -of default=noprint_wrappers=1:nokey=1 "$input_file" 2>/dev/null
        )
    fi

    [[ -z "$bd" || "$bd" == "0" || "$bd" == "N/A" ]] && bd=16

    sr=$(
        "$FFPROBE_BIN" -v error -select_streams a:0 \
            -show_entries stream=sample_rate \
            -of default=noprint_wrappers=1:nokey=1 "$input_file" 2>/dev/null
    )

    [[ -z "$sr" || "$sr" == "N/A" ]] && sr=44100

    DETECTED_BD="$bd"
    DETECTED_SR="$sr"
}

process_stem_normalization() {
    local input_file="$1"
    local output_dir="$2"
    local filename
    local target_path
    local gain_diff
    local ffmpeg_cmd=()

    filename="$(basename "$input_file")"
    target_path="$output_dir/$filename"
    mkdir -p "$output_dir"

    gain_diff="$(measure_gain_db "$input_file")"

    if [[ "$gain_diff" == "0" ]]; then
        echo -e "    🔊 Stem: loudness OK (no adjustment needed)" >&2
    else
        echo -e "    🔊 Normalizing Stem: ${gain_diff} dB" >&2
    fi

    ffmpeg_cmd=(
        "$FFMPEG_BIN" -nostdin -i "$input_file" -af "volume=${gain_diff}dB"
        -c:a alac -c:v copy -map 0
        -disposition:v:0 attached_pic -map_metadata 0
        -y -hide_banner -loglevel error "$target_path"
    )

    "${ffmpeg_cmd[@]}" || return 1
    [[ -f "$target_path" ]] || return 1
    echo "$target_path"
}

process_audio_specs() {
    local input_file="$1"
    local output_dir="$2"
    local normalize="${3:-1}"
    local filename
    local base_name
    local ext
    local target_path
    local gain_diff="0"
    local out_codec="pcm_s16be"
    local output_sr=""
    local ffmpeg_cmd=()

    filename="$(basename "$input_file")"
    base_name="${filename%.*}"
    ext="${filename##*.}"
    ext="${ext,,}"
    target_path="$output_dir/$base_name.aiff"

    mkdir -p "$output_dir"

    if [[ "$normalize" -eq 1 ]]; then
        gain_diff="$(measure_gain_db "$input_file")"
    fi

    get_audio_info "$input_file"

    if [[ "$ext" != "mp3" ]]; then
        case "$DETECTED_BD" in
            24|32) out_codec="pcm_s24be" ;;
            *) out_codec="pcm_s16be" ;;
        esac
    fi

    if [[ "$ext" == "mp3" ]]; then
        output_sr="44100"
    elif (( DETECTED_SR < 44100 )); then
        output_sr="44100"
    elif (( DETECTED_SR > 48000 )); then
        output_sr="48000"
    fi

    if [[ "$gain_diff" != "0" ]]; then
        echo -e "    🔊 → AIFF ${out_codec##*_} ${DETECTED_SR}Hz ${gain_diff}dB" >&2
    else
        echo -e "    🔄 → AIFF ${out_codec##*_} ${DETECTED_SR}Hz" >&2
    fi

    ffmpeg_cmd=("$FFMPEG_BIN" -nostdin -i "$input_file")
    [[ "$gain_diff" != "0" ]] && ffmpeg_cmd+=( -af "volume=${gain_diff}dB" )
    [[ -n "$output_sr" ]] && ffmpeg_cmd+=( -ar "$output_sr" )
    ffmpeg_cmd+=(
        -c:a "$out_codec"
        -map 0:a:0 -map 0:v? -c:v copy
        -disposition:v:0 attached_pic
        -map_metadata 0 -write_id3v2 1
        -y -hide_banner -loglevel error "$target_path"
    )

    "${ffmpeg_cmd[@]}" || return 1

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
    CURRENT_TIDAL=""
    [[ -f "$TIDAL_URL_FILE" ]] && CURRENT_TIDAL="$(<"$TIDAL_URL_FILE")"
    SELECTIONS=(1 1 1 1 1)
    LABELS=("🌊 Tidal Download" "🏷️  OneTagger" "🔊 Normalize → AIFF" "🔨 Stem Separation" "🎹 Detune Detection")

    while true; do
        clear
        echo ""
        echo -e "  ${CYAN}╔══════════════════════════════════════╗${NC}"
        echo -e "  ${CYAN}║         🎛️  DJ FACTORY              ║${NC}"
        echo -e "  ${CYAN}╚══════════════════════════════════════╝${NC}"
        echo ""
        echo -e "  ${YELLOW}INPUT ${NC} $CURRENT_INPUT"
        echo -e "  ${YELLOW}OUTPUT${NC} $CURRENT_OUTPUT"
        if [[ -n "$CURRENT_TIDAL" ]]; then
            echo -e "  ${YELLOW}TIDAL ${NC} $CURRENT_TIDAL"
        else
            echo -e "  ${YELLOW}TIDAL ${NC} (none saved)"
        fi
        echo ""
        echo -e "  ─────── Pipeline Steps ───────"

        for i in "${!LABELS[@]}"; do
            if [[ ${SELECTIONS[$i]} -eq 1 ]]; then
                echo -e "  ${GREEN}[$i] ■${NC} ${LABELS[$i]}"
            else
                echo -e "  [$i] □ ${LABELS[$i]}"
            fi
        done

        local file_count=0
        if [[ -d "$CURRENT_INPUT" ]]; then
            file_count=$(find "$CURRENT_INPUT" -maxdepth 1 -type f \
                \( -iname "*.flac" -o -iname "*.wav" -o -iname "*.aiff" -o -iname "*.m4a" -o -iname "*.mp3" \) 2>/dev/null | wc -l)
        fi

        echo ""
        echo -e "  ─────── Actions ─────────────"
        echo -e "  ${GREEN}[R]${NC} Run Pipeline  (${file_count} files)"
        echo -e "  [I] Edit Input   [O] Edit Output   [T] Edit Tidal URL"
        echo -e "  [Q] Quit"
        echo ""

        read -r -p "  > " choice
        case "$choice" in
            [0-4]) SELECTIONS[choice]=$((1 - SELECTIONS[choice])) ;;
            i|I)
                new_in="$(prompt_with_current "Input" "$CURRENT_INPUT")"
                [[ -n "$new_in" ]] && CURRENT_INPUT="$new_in"
                ;;
            o|O)
                new_out="$(prompt_with_current "Output" "$CURRENT_OUTPUT")"
                [[ -n "$new_out" ]] && CURRENT_OUTPUT="$new_out"
                ;;
            t|T)
                new_tidal="$(prompt_with_current "Tidal URL" "$CURRENT_TIDAL")"
                CURRENT_TIDAL="$(normalize_tidal_link "$new_tidal")"
                if [[ -n "$CURRENT_TIDAL" ]]; then
                    printf '%s\n' "$CURRENT_TIDAL" > "$TIDAL_URL_FILE"
                else
                    rm -f "$TIDAL_URL_FILE"
                fi
                ;;
            r|R)
                return 0
                ;;
            q|Q)
                echo ""
                exit 0
                ;;
        esac
    done
}

process_single_file() {
    local raw_file="$1"
    local filename
    local base_name
    local current_source
    local is_stem=0
    local stems_enabled=0
    local stem_created=0
    local processed_file=""
    local output_file=""
    local final_file=""
    local stem_file=""
    local detune_tag=""
    local check_file=""
    local detune_out=""
    local norm_flag
    local work_dir=""
    local stem_count_before=0
    local stem_count_after=0
    local created_stem=""
    local source_duration=0
    local processed_duration=0
    local stem_duration=0
    local file_failed=0

    filename="$(basename "$raw_file")"
    base_name="${filename%.*}"
    current_source="$(absolute_path "$raw_file")"
    source_duration="$(audio_duration_int "$current_source")"
    [[ "$filename" == *.stem.m4a ]] && is_stem=1
    [[ ${SELECTIONS[3]} -eq 1 && "$is_stem" -eq 0 ]] && stems_enabled=1

    echo "---------------------------------------------------"
    echo -e "🎵 ${CYAN}$filename${NC}"

    if [[ ${SELECTIONS[1]} -eq 1 ]]; then
        echo "    🏷️  Running OneTagger..."
        if ! timeout 2m "$BIN_DIR/onetagger-cli" autotagger --config "$ONETAGGER_CONF" --path "$current_source"; then
            echo -e "    ${YELLOW}⚠️ OneTagger failed or timed out; continuing.${NC}" >&2
            file_failed=1
        fi
    fi

    if [[ "$stems_enabled" -eq 1 ]]; then
        work_dir="$(create_file_work_dir "$base_name")" || return 1
    fi

    if [[ "$is_stem" -eq 1 ]]; then
        if [[ ${SELECTIONS[2]} -eq 1 ]]; then
            echo "    🔊 Normalizing Stem..."
            processed_file="$(process_stem_normalization "$current_source" "$CURRENT_OUTPUT")" || return 1
        else
            processed_file="$(safe_copy_to_dir "$current_source" "$CURRENT_OUTPUT")" || return 1
        fi
    elif [[ ${SELECTIONS[2]} -eq 1 ]] || is_non_aiff_source "$current_source"; then
        norm_flag="${SELECTIONS[2]}"
        if [[ "$stems_enabled" -eq 1 ]]; then
            processed_file="$(process_audio_specs "$current_source" "$work_dir" "$norm_flag")" || return 1
        else
            processed_file="$(process_audio_specs "$current_source" "$CURRENT_OUTPUT" "$norm_flag")" || return 1
        fi
    else
        if [[ "$stems_enabled" -eq 1 ]]; then
            processed_file="$(safe_copy_to_dir "$current_source" "$work_dir")" || return 1
        else
            processed_file="$(safe_copy_to_dir "$current_source" "$CURRENT_OUTPUT")" || return 1
        fi
    fi

    if [[ "$stems_enabled" -eq 1 ]]; then
        processed_duration="$(audio_duration_int "$processed_file")"
        if (( source_duration >= 60 && processed_duration > 0 && processed_duration < source_duration - 10 )); then
            echo -e "    ${YELLOW}⚠️ Skipping Stemgen: converted file is shorter than source (${processed_duration}s vs ${source_duration}s).${NC}" >&2
            echo -e "    ${YELLOW}   Delete/redownload this Tidal track if it is a 30-second preview.${NC}" >&2
            final_file="$(safe_copy_to_dir "$processed_file" "$CURRENT_OUTPUT")" || return 1
        else
            echo "    🔨 Handing off to Stemgen..."

            if ! safe_remove_stemgen_work "$base_name"; then
                echo -e "    ${YELLOW}⚠️ Failed to remove stale Stemgen work for $filename.${NC}" >&2
                file_failed=1
            fi
            stem_count_before=$(find "$CURRENT_OUTPUT" -maxdepth 1 -name "*.stem.m4a" -type f 2>/dev/null | wc -l)

            if ! run_interruptible_command "$STEMGEN_BIN" -i "$processed_file" -n "$STEM_MODEL" --device "$STEM_DEVICE" -o "$CURRENT_OUTPUT/"; then
                echo -e "    ${YELLOW}⚠️ Stemgen failed for $filename${NC}" >&2
                file_failed=1
            else
                stem_count_after=$(find "$CURRENT_OUTPUT" -maxdepth 1 -name "*.stem.m4a" -type f 2>/dev/null | wc -l)
                if [[ "$stem_count_after" -gt "$stem_count_before" ]]; then
                    created_stem="$(find "$CURRENT_OUTPUT" -maxdepth 1 -name "*.stem.m4a" -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)"
                fi

                if [[ -n "$created_stem" && -f "$created_stem" ]]; then
                    local expected_stem
                    expected_stem="$CURRENT_OUTPUT/${base_name}.stem.m4a"
                    if [[ "$created_stem" != "$expected_stem" ]]; then
                        mv "$created_stem" "$expected_stem" 2>/dev/null || true
                        if [[ -f "$expected_stem" ]]; then
                            stem_file="$expected_stem"
                        else
                            stem_file="$created_stem"
                        fi
                    else
                        stem_file="$created_stem"
                    fi

                    stem_duration="$(audio_duration_int "$stem_file")"
                    if (( processed_duration >= 60 && stem_duration > 0 && stem_duration < processed_duration - 10 )); then
                        echo -e "    ${YELLOW}⚠️ Stemgen produced a short stem (${stem_duration}s vs ${processed_duration}s); deleting it.${NC}" >&2
                        if ! rm -f -- "$stem_file"; then
                            file_failed=1
                        fi
                    else
                        stem_created=1
                        echo "    ✅ Stem Created: $(basename "$stem_file")"
                    fi
                else
                    echo -e "    ${YELLOW}⚠️ Stem file not found after stemgen run.${NC}" >&2
                    file_failed=1
                fi
            fi

            final_file="$(safe_copy_to_dir "$processed_file" "$CURRENT_OUTPUT")" || return 1
        fi
    fi

    if [[ -n "$final_file" && -f "$final_file" ]]; then
        output_file="$final_file"
    else
        output_file="$processed_file"
    fi

    if [[ ${SELECTIONS[4]} -eq 1 ]]; then
        echo "    🎹 Checking Detune..."
        check_file="$output_file"
        if [[ "$stem_created" -eq 1 && -f "$stem_file" ]]; then
            check_file="$stem_file"
        fi
        local detune_output
        if detune_output=$("$PYTHON_PROC" "$SCRIPT_DIR/analyze_stems.py" "$check_file" 2>&1); then
            detune_out="$(printf '%s\n' "$detune_output" | tail -n 1)"
            if [[ "$detune_out" =~ ^[+-][0-9]+c$ ]]; then
                detune_tag="$detune_out"
            fi
        else
            echo -e "    ${YELLOW}⚠️ Detune analysis failed for $filename; continuing.${NC}" >&2
            file_failed=1
        fi
    fi

    if [[ -n "$detune_tag" ]]; then
        if ! "$PYTHON_PROC" "$SCRIPT_DIR/write_tag.py" "$output_file" "$detune_tag"; then
            echo -e "    ${YELLOW}⚠️ Failed to tag $filename.${NC}" >&2
            file_failed=1
        elif [[ "$stem_created" -eq 1 && -f "$stem_file" ]]; then
            if ! "$PYTHON_PROC" "$SCRIPT_DIR/write_tag.py" "$stem_file" "$detune_tag"; then
                echo -e "    ${YELLOW}⚠️ Failed to tag $(basename "$stem_file").${NC}" >&2
                file_failed=1
            else
                echo "    🎹 Tagged: $detune_tag"
            fi
        else
            echo "    🎹 Tagged: $detune_tag"
        fi
    fi

    return "$file_failed"
}

# ==============================================
# PIPELINE
# ==============================================
run_pipeline() {
    local pipeline_failed=0
    local raw_file

    if ! mkdir -p "$CURRENT_OUTPUT" "$TMP_DIR"; then
        echo -e "${RED}❌ Failed to prepare pipeline directories.${NC}" >&2
        return 1
    fi
    RUN_TMP_DIR="$(mktemp -d "$TMP_DIR/run.XXXXXX")" || {
        echo -e "${RED}❌ Failed to create repo-local temp directory in $TMP_DIR${NC}" >&2
        return 1
    }

    if [[ ${SELECTIONS[0]} -eq 1 ]]; then
        echo -e "${YELLOW}🌊 Tidal Download Setup${NC}"

        if [[ ! -x "${TIDAL_BIN:-}" ]]; then
            # Tidal is an optional setup component; preserve the existing
            # degraded local-processing mode when its environment is absent.
            echo -e "${YELLOW}⚠️ Tidal environment is not available; skipping download step.${NC}" >&2
        elif ! "$BOOTSTRAP_PYTHON" "$SCRIPT_DIR/update_tidal_config.py" "$CURRENT_INPUT"; then
            echo -e "${RED}⚠️ Tidal configuration update failed; download skipped.${NC}" >&2
            pipeline_failed=1
        else
            local tidal_ready=1
            if ! "$TIDAL_BIN" cfg >/dev/null 2>&1; then
                echo -e "${RED}⚠️  Login Required...${NC}"
                if ! "$TIDAL_BIN" login; then
                    echo -e "${RED}⚠️ Tidal login failed; download skipped.${NC}" >&2
                    pipeline_failed=1
                    tidal_ready=0
                fi
            fi

            if [[ "$tidal_ready" -eq 1 ]]; then
                TIDAL_LINK="${CURRENT_TIDAL:-}"
                if [[ -f "$TIDAL_URL_FILE" ]]; then
                    SAVED_URL="$(<"$TIDAL_URL_FILE")"
                    SAVED_URL="$(normalize_tidal_link "$SAVED_URL")"
                    echo -e "    📂 Saved Tidal URL: ${CYAN}$SAVED_URL${NC}"
                    echo "    Press Enter to keep it, or edit/paste a different Tidal URL."
                    TIDAL_LINK="$(prompt_with_current "Tidal URL" "$SAVED_URL")"
                else
                    TIDAL_LINK="$(prompt_with_current "Tidal URL" "")"
                fi

                TIDAL_LINK="$(normalize_tidal_link "${TIDAL_LINK:-}")"
                CURRENT_TIDAL="$TIDAL_LINK"

                if [[ -n "${TIDAL_LINK:-}" ]]; then
                    if ! printf '%s\n' "$TIDAL_LINK" > "$TIDAL_URL_FILE"; then
                        echo -e "${RED}⚠️ Failed to save Tidal URL; download skipped.${NC}" >&2
                        pipeline_failed=1
                    else
                        echo -e "    🌊 Downloading: ${CYAN}$TIDAL_LINK${NC}"
                        if ! "$TIDAL_BIN" dl "$TIDAL_LINK"; then
                            echo -e "    ${YELLOW}⚠️ Tidal download failed. Check that the playlist is public/available to your logged-in Tidal account.${NC}" >&2
                            pipeline_failed=1
                        fi
                        quarantine_short_tidal_previews "$CURRENT_INPUT"
                    fi
                fi
            fi
        fi
    fi

    echo -e "\n${GREEN}🚀 PROCESSING BATCH...${NC}"

    if [[ ! -d "$CURRENT_INPUT" ]]; then
        echo -e "${RED}❌ Input directory does not exist: $CURRENT_INPUT${NC}" >&2
        return 1
    fi

    mapfile -d $'\0' -t FILE_LIST < <(
        find "$CURRENT_INPUT" -maxdepth 1 -type f \
            \( -iname "*.flac" -o -iname "*.wav" -o -iname "*.aiff" -o -iname "*.m4a" -o -iname "*.mp3" \) -print0
    )

    if [[ ${#FILE_LIST[@]} -eq 0 ]]; then
        echo -e "${YELLOW}⚠️ No audio files found in $CURRENT_INPUT${NC}"
        return "$pipeline_failed"
    fi

    for raw_file in "${FILE_LIST[@]}"; do
        [[ -z "$raw_file" ]] && continue
        if ! process_single_file "$raw_file"; then
            echo -e "${YELLOW}⚠️ Failed to process $(basename "$raw_file"); continuing with next file.${NC}" >&2
            pipeline_failed=1
        fi
    done

    return "$pipeline_failed"
}
