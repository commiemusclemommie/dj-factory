import json
import os
import shutil
import sys
import tempfile


def atomic_write_json(path, data):
    """Atomically replace a file, preserving a symlink at ``path``."""
    replacement_path = os.path.realpath(path) if os.path.islink(path) else path
    if os.path.islink(path) and not os.path.isfile(replacement_path):
        raise OSError(f"settings symlink target is not a regular file: {replacement_path}")

    directory = os.path.dirname(os.path.abspath(replacement_path)) or "."
    temporary_path = None

    try:
        file_descriptor, temporary_path = tempfile.mkstemp(
            prefix=f".{os.path.basename(replacement_path)}.",
            suffix=".tmp",
            dir=directory,
        )
        with os.fdopen(file_descriptor, "w", encoding="utf-8") as config_file:
            json.dump(data, config_file, indent=4)
            config_file.write("\n")
            config_file.flush()
            os.fsync(config_file.fileno())

        if os.path.exists(replacement_path):
            shutil.copymode(replacement_path, temporary_path)
        os.replace(temporary_path, replacement_path)
        temporary_path = None

        directory_fd = os.open(directory, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    except Exception:
        if temporary_path is not None:
            try:
                os.unlink(temporary_path)
            except OSError:
                pass
        raise


def load_json_object(path):
    """Return settings or raise for missing, unreadable, or malformed data."""
    with open(path, encoding="utf-8") as config_file:
        data = json.load(config_file)
    if not isinstance(data, dict):
        raise ValueError("settings JSON must contain an object")
    return data


def choose_config(paths):
    primary_path, legacy_path = paths
    invalid_paths = []

    for path in paths:
        if not os.path.lexists(path):
            continue
        try:
            return path, load_json_object(path)
        except (OSError, ValueError, json.JSONDecodeError) as error:
            invalid_paths.append((path, error))
            print(f"⚠️ Failed to read {path}: {error}", file=sys.stderr)

    # A malformed primary is repaired in place only when no valid legacy file
    # exists. If the primary is a symlink, atomic_write_json updates its target
    # and refuses a dangling link rather than replacing the link itself.
    if any(path == primary_path for path, _ in invalid_paths) or not os.path.lexists(legacy_path):
        return primary_path, {}
    return primary_path, {}


if len(sys.argv) < 2:
    print("Error: No target directory provided.")
    sys.exit(1)

target_dir = os.path.expanduser(sys.argv[1])
ffmpeg_bin = os.environ.get("FFMPEG_BIN") or shutil.which("ffmpeg") or "ffmpeg"

DESIRED_SETTINGS = {
    "download_base_path": target_dir,
    "skip_existing": False,
    "video_download": False,
    "path_binary_ffmpeg": ffmpeg_bin,
    "extract_flac": True,
    "symlink_to_track": False,
    "quality_audio": "HI_RES_LOSSLESS",
    "format_playlist": "{artist_name} - {track_title}",
    "format_track": "{artist_name} - {track_title}",
    "format_album": "{artist_name} - {track_title}",
}

possible_paths = [
    os.path.expanduser("~/.config/tidal_dl_ng/settings.json"),
    os.path.expanduser("~/.tidal-dl.json"),
]

try:
    config_path, data = choose_config(possible_paths)
    if os.path.lexists(config_path):
        print(f"Using config at: {config_path}")
    else:
        print(f"No config found. Creating new at: {config_path}")
        os.makedirs(os.path.dirname(config_path), exist_ok=True)

    for key, value in DESIRED_SETTINGS.items():
        data[key] = value

    atomic_write_json(config_path, data)
    print("✅ Config updated successfully.")
except Exception as error:
    print(f"❌ Failed to update {config_path}: {error}", file=sys.stderr)
    sys.exit(1)
