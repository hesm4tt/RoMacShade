#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-27.0.0-Beta.3.app/Contents/Developer}"
platform="${1:-device}"
case "$platform" in
  device) sdk=iphoneos; target=arm64-apple-ios15.0 ;;
  simulator) sdk=iphonesimulator; target=arm64-apple-ios15.0-simulator ;;
  *) echo "Usage: $0 [device|simulator]" >&2; exit 2 ;;
esac
sdk_path="$(xcrun --sdk "$sdk" --show-sdk-path)"
compiler="$(xcrun --sdk "$sdk" --find clang++)"
out="build/ios-source/$platform"
mkdir -p "$out/cache"
python3 iOS/Tools/build_effect_pack.py --output "$out/RoMacShade-effects.rmpack"
base=(-std=c++17 -O2 -target "$target" -isysroot "$sdk_path" -DMACSHADE_IOS=1
  -I Sources -I iOS/Sources -I "$out" -isystem ThirdParty/SPIRV-Cross -isystem ThirdParty/ReShadeFX/source
  -fvisibility=hidden -fvisibility-inlines-hidden)
objects=()
command_stamp="$out/cache/compiler-command.txt"
command_text="$compiler ${base[*]}"
rebuild=0
if [[ -f "$command_stamp" && "$(cat "$command_stamp")" != "$command_text" ]]; then rebuild=1; fi
for source in ThirdParty/ReShadeFX/source/*.cpp ThirdParty/SPIRV-Cross/*.cpp Sources/FXCompiler.cpp; do
  object="$out/cache/$(basename "${source%.cpp}").o"
  objects+=("$object")
  if [[ "$rebuild" == 1 || ! -f "$object" || "$source" -nt "$object" ]] ||
    [[ -n "$(find Sources ThirdParty -type f \( -name '*.h' -o -name '*.hpp' -o -name '*.inl' \) -newer "$object" -print -quit)" ]]; then
    printf 'Compiling %s\n' "$source"
    "$compiler" "${base[@]}" -c "$source" -o "$object"
  fi
done
printf '%s' "$command_text" > "$command_stamp"
"$compiler" "${base[@]}" -fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-deprecated-declarations \
  -dynamiclib Sources/MacShade.mm Sources/Hooks.mm Sources/FXRuntime.mm Sources/DepthCapture.mm \
  Sources/FXPreset.mm Sources/FXChain.mm iOS/Sources/RMAssets.mm iOS/Sources/RMOverlay.mm \
  "${objects[@]}" -framework UIKit -framework Foundation -framework Metal -framework QuartzCore \
  -framework CoreGraphics -framework ImageIO -framework UniformTypeIdentifiers -lz \
  -Wl,-dead_strip -Wl,-sectcreate,__DATA,__rmpack,"$out/RoMacShade-effects.rmpack" \
  -install_name @rpath/RoMacShade.dylib -o "$out/RoMacShade.dylib"
strip -S -x "$out/RoMacShade.dylib"
codesign --force --sign - "$out/RoMacShade.dylib"
codesign --verify --strict "$out/RoMacShade.dylib"
shasum -a 256 "$out/RoMacShade.dylib" "$out/RoMacShade-effects.rmpack" > "$out/SHA256SUMS"
echo "Built $out/RoMacShade.dylib ($platform). Physical iOS requires LiveContainer Tweaks -> Sign."
