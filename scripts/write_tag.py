#!/usr/bin/env python3
import sys

try:
    from mutagen.mp4 import MP4
    from mutagen.aiff import AIFF
    from mutagen.id3 import COMM
    from mutagen.flac import FLAC
    from mutagen.wave import WAVE
except ImportError as e:
    sys.stderr.write(f"Mutagen import error: {e}\n")
    sys.exit(1)

def add_comment(path, text):
    try:
        path_lower = path.lower()

        # --- AIFF / AIF ---
        if path_lower.endswith(('.aiff', '.aif')):
            audio = AIFF(path)
            if audio.tags is None:
                audio.add_tags()
            existing = [c.text[0] for c in audio.tags.getall('COMM')] if audio.tags else []
            if text not in existing:
                audio.tags.add(COMM(encoding=3, lang='eng', desc='', text=[text]))
            audio.save()

        # --- M4A / MP4 ---
        elif path_lower.endswith(('.m4a', '.mp4')):
            audio = MP4(path)
            if audio.tags is None:
                audio.add_tags()
            existing = audio.tags.get('\xa9cmt', [''])[0]
            if text not in existing:
                audio.tags['\xa9cmt'] = [f"{existing} {text}".strip()]
                audio.save()

        # --- FLAC ---
        elif path_lower.endswith('.flac'):
            audio = FLAC(path)
            existing = audio.get("COMMENT", [])
            if text not in existing:
                audio["COMMENT"] = existing + [text]
                audio.save()

        # --- WAV ---
        elif path_lower.endswith('.wav'):
            audio = WAVE(path)
            if audio.tags is None:
                audio.add_tags()
            existing = [c.text[0] for c in audio.tags.getall('COMM')] if audio.tags else []
            if text not in existing:
                audio.tags.add(COMM(encoding=3, lang='eng', desc='', text=[text]))
            audio.save()

        # --- MP3 ---
        elif path_lower.endswith('.mp3'):
            from mutagen.mp3 import MP3
            audio = MP3(path)
            if audio.tags is None:
                audio.add_tags()
            existing = [c.text[0] for c in audio.tags.getall('COMM')] if audio.tags else []
            if text not in existing:
                audio.tags.add(COMM(encoding=3, lang='eng', desc='', text=[text]))
            audio.save()

        else:
            sys.stderr.write(f"Unsupported file type for tagging: {path}\n")

    except Exception as e:
        sys.stderr.write(f"Tagging error for {path}: {e}\n")

if __name__ == "__main__":
    if len(sys.argv) > 2:
        add_comment(sys.argv[1], sys.argv[2])
