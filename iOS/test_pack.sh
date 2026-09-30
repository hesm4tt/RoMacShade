#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/ios-source/tests
compiler="$(xcrun --find clang++)"
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
"$compiler" -std=c++17 -isysroot "$sdk_path" -fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-deprecated-declarations \
  -I iOS/Sources iOS/Sources/RMAssets.mm iOS/Tests/PackTests.mm \
  -framework Foundation -lz -o build/ios-source/tests/PackTests
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/romacshade-pack-test.XXXXXX")"
build/ios-source/tests/PackTests build/ios-source/device/RoMacShade-effects.rmpack "$test_dir"
