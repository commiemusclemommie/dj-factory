#!/usr/bin/env python3
import urllib.request
import json
import sys
import platform

# Detect OS
system_os = platform.system() # Returns 'Linux' or 'Darwin' (Mac)

api_url = "https://api.github.com/repos/Marekkon5/onetagger/releases/latest"

try:
    req = urllib.request.Request(api_url, data=None, headers={'User-Agent': 'Mozilla/5.0'})
    with urllib.request.urlopen(req) as response:
        data = json.loads(response.read().decode())

        for asset in data.get('assets', []):
            url = asset.get('browser_download_url', '')

            # LOGIC FOR LINUX
            if system_os == "Linux":
                if 'linux-cli' in url and url.endswith('.tar.gz'):
                    print(url); sys.exit(0)

            # LOGIC FOR MAC
            elif system_os == "Darwin":
                # Matches "macos-cli" or "macos-universal-cli"
                if 'macos' in url and 'cli' in url and url.endswith('.tar.gz'):
                    print(url); sys.exit(0)

except Exception:
    sys.exit(1)
