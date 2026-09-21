#!/bin/bash
#
# Build script for RoAndroidShade (VK_LAYER_RoShade)
# Targets Android arm64-v8a using Android NDK
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANDROID_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DIST_DIR="${ANDROID_ROOT}/dist"
BUILD_DIR="${ANDROID_ROOT}/build-android-arm64"

# 1. Locate Android NDK
NDK_PATH=""

if [ -n "$1" ] && [ -d "$1" ]; then
    NDK_PATH="$1"
elif [ -n "$ANDROID_NDK_HOME" ] && [ -d "$ANDROID_NDK_HOME" ]; then
    NDK_PATH="$ANDROID_NDK_HOME"
elif [ -n "$ANDROID_NDK_ROOT" ] && [ -d "$ANDROID_NDK_ROOT" ]; then
    NDK_PATH="$ANDROID_NDK_ROOT"
elif [ -n "$NDK_HOME" ] && [ -d "$NDK_HOME" ]; then
    NDK_PATH="$NDK_HOME"
else
    # Check default macOS / Linux locations
    CANDIDATES=(
        "$HOME/Library/Android/sdk/ndk/"*
        "/usr/local/share/android-ndk"*
        "/opt/android-ndk"*
        "$HOME/Android/Sdk/ndk/"*
    )
    for c in "${CANDIDATES[@]}"; do
        if [ -d "$c" ]; then
            NDK_PATH="$c"
            break
        fi
    done
fi

if [ -z "$NDK_PATH" ] || [ ! -d "$NDK_PATH" ]; then
    echo "================================================================"
    echo " [ERROR] Android NDK not found!"
    echo "================================================================"
    echo "Please set ANDROID_NDK_HOME or pass the NDK directory as an argument:"
    echo "  export ANDROID_NDK_HOME=~/Library/Android/sdk/ndk/<version>"
    echo "  ./build_android.sh [path-to-ndk]"
    echo ""
    echo "On macOS, you can install the NDK via Homebrew:"
    echo "  brew install --cask android-ndk"
    echo "Or via Android Studio -> SDK Manager -> SDK Tools -> NDK."
    echo "================================================================"
    exit 1
fi

echo "==> Using Android NDK: ${NDK_PATH}"

TOOLCHAIN_FILE="${NDK_PATH}/build/cmake/android.toolchain.cmake"
if [ ! -f "${TOOLCHAIN_FILE}" ]; then
    echo "[ERROR] Could not find android.toolchain.cmake in ${NDK_PATH}"
    exit 1
fi

# 2. Configure with CMake
mkdir -p "${BUILD_DIR}"
mkdir -p "${DIST_DIR}"

echo "==> Configuring CMake for arm64-v8a (Android API 29+)..."
cmake -B "${BUILD_DIR}" -S "${ANDROID_ROOT}" \
    -DCMAKE_TOOLCHAIN_FILE="${TOOLCHAIN_FILE}" \
    -DANDROID_ABI=arm64-v8a \
    -DANDROID_PLATFORM=android-29 \
    -DANDROID_STL=c++_static \
    -DCMAKE_BUILD_TYPE=Release

# 3. Build the layer shared library
echo "==> Building libVkLayer_RoShade.so..."
cmake --build "${BUILD_DIR}" --config Release -j$(sysctl -n hw.ncpu 2>/dev/null || nproc || echo 4)

# 4. Copy artifacts to dist/
cp "${BUILD_DIR}/libVkLayer_RoShade.so" "${DIST_DIR}/libVkLayer_RoShade.so"
cp "${ANDROID_ROOT}/layer/VkLayer_RoShade.json" "${DIST_DIR}/VkLayer_RoShade.json"

echo "================================================================"
echo " [SUCCESS] RoAndroidShade built successfully!"
echo " Artifacts generated in: ${DIST_DIR}"
echo "   - ${DIST_DIR}/libVkLayer_RoShade.so"
echo "   - ${DIST_DIR}/VkLayer_RoShade.json"
echo "================================================================"
