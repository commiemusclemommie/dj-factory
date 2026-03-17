import json
import sys
import os

# 1. VALIDATE INPUT
if len(sys.argv) < 2:
    print("Error: No target directory provided.")
    sys.exit(1)

# Ensure we handle "~" if passed in quotes
target_dir = os.path.expanduser(sys.argv[1])

# 2. DEFINE THE "GOLDEN STANDARD" SETTINGS
# We define these once so they are applied consistently whether
# we are updating an old file or creating a new one.
DESIRED_SETTINGS = {
    "download_base_path": target_dir,
    "video_download": False,
    "path_binary_ffmpeg": "/usr/bin/ffmpeg",
    "extract_flac": True,
    "symlink_to_track": False,  # Turn this OFF if you want real files, not links
    "quality_audio": "HI_RES_LOSSLESS",

    # NEW FLAT NAMING STANDARDS
    # We remove "Playlists/" and "Tracks/" so files sit directly in the base path
    "format_playlist": "{artist_name} - {track_title}",
    "format_track": "{artist_name} - {track_title}",
    "format_album": "{artist_name} - {track_title}"

}

# 3. LOCATE CONFIG
possible_paths = [
    os.path.expanduser("~/.config/tidal_dl_ng/settings.json"),
    os.path.expanduser("~/.tidal-dl.json")
]

config_found = False

# 4. ATTEMPT TO UPDATE EXISTING
for config_path in possible_paths:
    if os.path.exists(config_path):
        print(f"Found config at: {config_path}")
        try:
            with open(config_path, 'r') as f:
                data = json.load(f)

            # Update/Overwrite keys with our Desired Settings
            for key, value in DESIRED_SETTINGS.items():
                data[key] = value

            # Save back
            with open(config_path, 'w') as f:
                json.dump(data, f, indent=4)

            print("✅ Config updated successfully.")
            config_found = True
            break # Stop after finding the first valid config
        except Exception as e:
            print(f"⚠️ Failed to update {config_path}: {e}")

# 5. CREATE NEW IF MISSING
if not config_found:
    default_path = possible_paths[0]
    print(f"No config found. Creating new at: {default_path}")

    try:
        os.makedirs(os.path.dirname(default_path), exist_ok=True)
        with open(default_path, 'w') as f:
            json.dump(DESIRED_SETTINGS, f, indent=4)
        print("✅ New config created.")
    except Exception as e:
        print(f"❌ Critical Error creating config: {e}")
        sys.exit(1)
