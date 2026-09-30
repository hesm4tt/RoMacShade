#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source_dir="build/ios-source/device"
release_dir="build/ios-source/effect-hosting"
bash iOS/build_ios.sh device
mkdir -p "$release_dir"
cp "$source_dir/RoMacShade-effects.rmpack" "$release_dir/RoMacShade-effects.rmpack"
cp "$source_dir/RoMacShade-effects.json" "$release_dir/RoMacShade-effects.json"
cp iOS/effects-hosting/RELEASE_NOTES.md "$release_dir/RELEASE_NOTES.md"
cp iOS/effects-hosting/README.md "$release_dir/README.md"
(cd "$release_dir" && shasum -a 256 RoMacShade-effects.rmpack RoMacShade-effects.json > SHA256SUMS)
echo "Prepared effect-library release assets in $release_dir"
