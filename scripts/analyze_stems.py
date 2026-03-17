#!/usr/bin/env python3
"""
Detune Detector — estimates tuning deviation in cents.

For stem files (.stem.m4a): analyzes individual stem channels (bass, other,
vocals) and takes the median — cleaner signal = better estimate.

For regular audio files: analyzes the full mix directly using librosa's
tuning estimator. Less accurate than stems but still useful.

Output: "+12c" or "-8c" (only if |deviation| > 5 cents), else nothing.
"""
import librosa
import os
import sys
import subprocess
import tempfile
import warnings
import numpy as np

warnings.filterwarnings("ignore")


def analyze_tuning(path):
    """Estimate tuning deviation in cents from A440."""
    try:
        y, sr = librosa.load(path, mono=True, offset=30, duration=30)
        if len(y) < sr * 2:
            # File too short — try from the beginning
            y, sr = librosa.load(path, mono=True, duration=30)
        if len(y) < sr:
            return 0.0
        return librosa.estimate_tuning(y=y, sr=sr) * 100
    except Exception:
        return 0.0


def analyze_stem_file(filepath):
    """Extract and analyze individual stem channels from a .stem.m4a."""
    deviations = []

    # Stem files typically have streams: 0=mix, 1=drums, 2=bass, 3=other, 4=vocals
    # We skip drums (mostly unpitched) and the mix (redundant)
    for idx in [2, 3, 4]:
        fd, temp = tempfile.mkstemp(suffix='.wav')
        os.close(fd)
        try:
            subprocess.run([
                '/usr/bin/ffmpeg', '-v', 'error',
                '-i', filepath,
                '-map', f'0:{idx}',
                '-c:a', 'pcm_s16le', '-y', temp
            ], capture_output=True, stdin=subprocess.DEVNULL)

            if os.path.getsize(temp) > 1000:
                cents = analyze_tuning(temp)
                if abs(cents) > 5:
                    deviations.append(cents)
        finally:
            os.unlink(temp)

    return deviations


def analyze_audio_file(filepath):
    """Analyze tuning of a regular audio file (full mix)."""
    cents = analyze_tuning(filepath)
    if abs(cents) > 5:
        return [cents]
    return []


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(0)

    filepath = sys.argv[1]

    if not os.path.isfile(filepath):
        sys.stderr.write(f"File not found: {filepath}\n")
        sys.exit(1)

    # Decide analysis mode based on file type
    if filepath.lower().endswith('.stem.m4a'):
        deviations = analyze_stem_file(filepath)
    else:
        deviations = analyze_audio_file(filepath)

    if deviations:
        final_cents = int(np.median(deviations))
        if abs(final_cents) > 5:
            print(f"{final_cents:+d}c")
