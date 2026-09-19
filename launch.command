#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
./build.sh
python3 Tools/roblox_host.py run "$@"
