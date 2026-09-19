#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
SDK="$(xcrun --sdk macosx --show-sdk-path)"
CXX="$(xcrun --find clang++)"
BASE=(-std=c++17 -O2 -mmacosx-version-min=12.0 -isysroot "$SDK" -I Sources -isystem ThirdParty/SPIRV-Cross -isystem ThirdParty/ReShadeFX/source)
FLAGS=("${BASE[@]}" -fobjc-arc -fblocks -Wall -Wextra -Werror -fvisibility=hidden -fvisibility-inlines-hidden)
LDFLAGS=(-Wl,-dead_strip)
# Set ARCHS="arm64 x86_64" to cross-build a universal library and executables.
ARCH_FLAGS=()
for arch in ${ARCHS:-$(uname -m)}; do ARCH_FLAGS+=(-arch "$arch"); done
cache_id="$(printf '%s' "$PWD ${ARCHS:-$(uname -m)}" | cksum | cut -d ' ' -f 1)"
BUILD_CACHE="${MACSHADE_BUILD_CACHE:-${TMPDIR:-/tmp}/macshade-build-${UID}-${cache_id}}"
mkdir -p "$BUILD_CACHE"
COMPILER_OBJECTS=()
command_stamp="$BUILD_CACHE/compiler-command.txt"
compiler_command="$CXX ${BASE[*]} ${ARCH_FLAGS[*]}"
force_compiler_rebuild=0
if [[ -f "$command_stamp" && "$(cat "$command_stamp")" != "$compiler_command" ]]; then
  force_compiler_rebuild=1
fi
for source in ThirdParty/ReShadeFX/source/*.cpp ThirdParty/SPIRV-Cross/*.cpp Sources/FXCompiler.cpp; do
  object="$BUILD_CACHE/$(basename "${source%.cpp}").o"
  COMPILER_OBJECTS+=("$object")
  if [[ "$force_compiler_rebuild" == 1 || ! -f "$object" || "$source" -nt "$object" ]] || \
     [[ "$source" == Sources/FXCompiler.cpp && Sources/FXCompiler.hpp -nt "$object" ]] || \
     [[ -n "$(find ThirdParty -type f \( -name '*.hpp' -o -name '*.h' -o -name '*.inl' \) -newer "$object" -print -quit 2>/dev/null)" ]]; then
    printf 'Compiling %s\n' "$source"
    "$CXX" "${BASE[@]}" "${ARCH_FLAGS[@]}" -c "$source" -o "$object"
  fi
done
printf '%s' "$compiler_command" > "$command_stamp"
"$CXX" "${FLAGS[@]}" "${ARCH_FLAGS[@]}" "${LDFLAGS[@]}" -dynamiclib Sources/MacShade.mm Sources/Hooks.mm Sources/FXRuntime.mm Sources/DepthCapture.mm "${COMPILER_OBJECTS[@]}" \
  -framework Foundation -framework Metal -framework QuartzCore -framework CoreGraphics -framework ImageIO \
  -install_name @rpath/libMacShade.dylib -o build/libMacShade.dylib
"$CXX" "${FLAGS[@]}" "${ARCH_FLAGS[@]}" "${LDFLAGS[@]}" Sources/Demo.mm Sources/Overlay.mm Sources/FXPreset.mm Sources/FXChain.mm \
  -L build -lMacShade -Wl,-rpath,@executable_path/../Frameworks -Wl,-rpath,@loader_path \
  -framework AppKit -framework MetalKit -framework Metal -framework QuartzCore -framework UniformTypeIdentifiers \
  -o build/MacShadeDemo
"$CXX" "${FLAGS[@]}" "${ARCH_FLAGS[@]}" "${LDFLAGS[@]}" -dynamiclib Sources/HostEntry.mm Sources/HardwareLock.mm Sources/HostOverlay.mm Sources/Overlay.mm Sources/FXPreset.mm Sources/FXChain.mm \
  -L build -lMacShade -Wl,-rpath,@loader_path \
  -framework AppKit -framework Metal -framework QuartzCore -framework UniformTypeIdentifiers -framework IOKit \
  -install_name @rpath/libMacShadeHost.dylib -o build/libMacShadeHost.dylib
"$CXX" "${FLAGS[@]}" "${ARCH_FLAGS[@]}" "${LDFLAGS[@]}" Sources/HostProbe.mm \
  -framework Foundation -framework Security -o build/HostProbe
"$CXX" "${FLAGS[@]}" "${ARCH_FLAGS[@]}" "${LDFLAGS[@]}" Tests/HostHarness.mm \
  -framework AppKit -framework Metal -framework MetalKit -framework QuartzCore -o build/HostHarness
"$CXX" "${FLAGS[@]}" "${ARCH_FLAGS[@]}" "${LDFLAGS[@]}" Tests/RendererTests.mm \
  -L build -lMacShade -Wl,-rpath,@loader_path \
  -framework Foundation -framework Metal -o build/RendererTests
"$CXX" "${FLAGS[@]}" "${ARCH_FLAGS[@]}" "${LDFLAGS[@]}" Tests/FXTests.mm \
  -L build -lMacShade -Wl,-rpath,@loader_path \
  -framework Foundation -framework Metal -o build/FXTests
"$CXX" "${FLAGS[@]}" "${ARCH_FLAGS[@]}" "${LDFLAGS[@]}" Sources/FXCheck.mm \
  -L build -lMacShade -Wl,-rpath,@loader_path \
  -framework Foundation -framework Metal -o build/FXCheck
"$CXX" "${FLAGS[@]}" "${ARCH_FLAGS[@]}" "${LDFLAGS[@]}" Tests/PresetTests.mm Sources/FXPreset.mm \
  -framework Foundation -o build/PresetTests
"$CXX" "${FLAGS[@]}" "${ARCH_FLAGS[@]}" "${LDFLAGS[@]}" Tests/ChainTests.mm Sources/FXPreset.mm Sources/FXChain.mm \
  -L build -lMacShade -Wl,-rpath,@loader_path -framework Foundation -framework Metal -o build/ChainTests
for test_source in Tests/DepthTests.mm Tests/DepthCaptureTests.mm; do
  "$CXX" "${FLAGS[@]}" "${ARCH_FLAGS[@]}" "${LDFLAGS[@]}" "$test_source" \
    -L build -lMacShade -Wl,-rpath,@loader_path -framework Foundation -framework Metal -o "build/$(basename "${test_source%.mm}")"
done
rm -rf build/MacShadeDemo.app
mkdir -p build/MacShadeDemo.app/Contents/{MacOS,Frameworks}
cp build/MacShadeDemo build/MacShadeDemo.app/Contents/MacOS/
cp build/libMacShade.dylib build/MacShadeDemo.app/Contents/Frameworks/
mkdir -p build/MacShadeDemo.app/Contents/Resources
rm -rf build/MacShadeDemo.app/Contents/Resources/{Effects,Presets}
ditto Effects build/MacShadeDemo.app/Contents/Resources/Effects
ditto Presets build/MacShadeDemo.app/Contents/Resources/Presets
cat > build/MacShadeDemo.app/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MacShadeDemo</string>
<key>CFBundleIdentifier</key><string>local.macshade.demo</string>
<key>CFBundleName</key><string>MacShade Demo</string>
<key>CFBundleVersion</key><string>4</string>
<key>CFBundleShortVersionString</key><string>0.4</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSHighResolutionCapable</key><true/>
<key>LSMinimumSystemVersion</key><string>12.0</string>
</dict></plist>
PLIST
# Strip demo binaries
strip -x build/libMacShade.dylib
strip -x build/libMacShadeHost.dylib
strip -x build/MacShadeDemo.app/Contents/Frameworks/libMacShade.dylib
strip -x build/MacShadeDemo.app/Contents/MacOS/MacShadeDemo

codesign --force --sign - build/MacShadeDemo.app/Contents/Frameworks/libMacShade.dylib
codesign --force --sign - build/MacShadeDemo.app
codesign --force --sign - build/libMacShade.dylib
codesign --force --sign - build/libMacShadeHost.dylib
codesign --force --sign - build/HostHarness
mkdir -p build/MetalHostHarness.app/Contents/MacOS
cp build/HostHarness build/MetalHostHarness.app/Contents/MacOS/
cat > build/MetalHostHarness.app/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>HostHarness</string>
<key>CFBundleIdentifier</key><string>local.macshade.hostharness</string>
<key>CFBundleName</key><string>Metal Host Harness</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSHighResolutionCapable</key><true/>
<key>LSMinimumSystemVersion</key><string>12.0</string>
</dict></plist>
PLIST
codesign --force --sign - build/MetalHostHarness.app

# Build standalone MacShade launcher app
"$CXX" "${FLAGS[@]}" "${ARCH_FLAGS[@]}" "${LDFLAGS[@]}" Sources/AppMain.mm Sources/HostLauncher.mm Sources/HardwareLock.mm \
  -framework AppKit -framework UniformTypeIdentifiers -framework Security -framework IOKit \
  -o build/MacShade

# Generate icon if missing
if [[ ! -f build/AppIcon.icns ]]; then
  "$CXX" -std=c++17 -framework AppKit Tools/make_icon.mm -o /tmp/make_icon && /tmp/make_icon build/AppIcon.icns
fi

rm -rf build/MacShade.app
mkdir -p build/MacShade.app/Contents/MacOS build/MacShade.app/Contents/Frameworks build/MacShade.app/Contents/Resources
cp build/MacShade build/MacShade.app/Contents/MacOS/
cp build/MacShadeDemo build/MacShade.app/Contents/MacOS/
cp build/libMacShade.dylib build/libMacShadeHost.dylib build/MacShade.app/Contents/Frameworks/
cp build/AppIcon.icns build/MacShade.app/Contents/Resources/
rm -rf build/MacShade.app/Contents/Resources/{Effects,Presets}
ditto Effects build/MacShade.app/Contents/Resources/Effects
ditto Presets build/MacShade.app/Contents/Resources/Presets

# Strip all app binaries of local symbols
strip -x build/MacShade.app/Contents/MacOS/MacShade
strip -x build/MacShade.app/Contents/MacOS/MacShadeDemo
strip -x build/MacShade.app/Contents/Frameworks/libMacShade.dylib
strip -x build/MacShade.app/Contents/Frameworks/libMacShadeHost.dylib
cat > build/MacShade.app/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MacShade</string>
<key>CFBundleIdentifier</key><string>local.macshade.app</string>
<key>CFBundleName</key><string>MacShade</string>
<key>CFBundleDisplayName</key><string>MacShade</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>0.0.1</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSHighResolutionCapable</key><true/>
<key>LSMinimumSystemVersion</key><string>12.0</string>
</dict></plist>
PLIST
codesign --force --sign - build/MacShade.app/Contents/Frameworks/libMacShade.dylib
codesign --force --sign - build/MacShade.app/Contents/Frameworks/libMacShadeHost.dylib
codesign --force --sign - build/MacShade.app/Contents/MacOS/MacShadeDemo
codesign --force --sign - build/MacShade.app

# Build DMG installer
./Tools/build_dmg.sh

printf 'Built Metal runtime, host overlay library, host tools, MacShade.app, and MacShade-v0.0.1.dmg\n'
