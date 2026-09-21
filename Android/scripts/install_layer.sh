#!/bin/bash
#
# Installer script for RoAndroidShade (VK_LAYER_RoShade)
# Configures Android Vulkan GPU debug layer settings over ADB
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANDROID_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DIST_DIR="${ANDROID_ROOT}/dist"

SO_FILE="${DIST_DIR}/libVkLayer_RoShade.so"
JSON_FILE="${DIST_DIR}/VkLayer_RoShade.json"

# 1. Locate ADB
ADB_BIN=""
if command -v adb >/dev/null 2>&1; then
    ADB_BIN="adb"
elif [ -f "$HOME/Library/Android/sdk/platform-tools/adb" ]; then
    ADB_BIN="$HOME/Library/Android/sdk/platform-tools/adb"
elif [ -f "$HOME/Android/Sdk/platform-tools/adb" ]; then
    ADB_BIN="$HOME/Android/Sdk/platform-tools/adb"
fi

if [ -z "$ADB_BIN" ]; then
    echo "================================================================"
    echo " [ERROR] Android Debug Bridge (adb) not found!"
    echo "================================================================"
    echo "Please ensure adb is installed and in your PATH."
    echo "On macOS with Homebrew:"
    echo "  brew install android-platform-tools"
    echo "================================================================"
    exit 1
fi

# 2. Check Device Connectivity
DEVICE_COUNT=$("$ADB_BIN" devices | grep -v "List" | grep "device$" | wc -l | tr -d ' ')
if [ "$DEVICE_COUNT" -eq 0 ]; then
    echo "================================================================"
    echo " [ERROR] No Android device connected via ADB!"
    echo "================================================================"
    echo "1. Connect your Android device via USB (or wireless debugging)."
    echo "2. Enable Developer Options on your device:"
    echo "   Settings -> About Phone -> Tap 'Build Number' 7 times."
    echo "3. Enable 'USB Debugging' in Developer Options."
    echo "4. Allow USB debugging prompt on your phone screen."
    echo "================================================================"
    exit 1
fi

DEVICE_NAME=$("$ADB_BIN" shell getprop ro.product.model | tr -d '\r')
ANDROID_VER=$("$ADB_BIN" shell getprop ro.build.version.release | tr -d '\r')
echo "==> Connected to: ${DEVICE_NAME} (Android ${ANDROID_VER})"

# 3. Check for built artifacts
if [ ! -f "${SO_FILE}" ] || [ ! -f "${JSON_FILE}" ]; then
    echo "[!] Artifacts not found in ${DIST_DIR}."
    echo "==> Attempting to build automatically..."
    "${SCRIPT_DIR}/build_android.sh"
fi

# 4. Check if Roblox is installed
ROBLOX_PKG="com.roblox.client"
if ! "$ADB_BIN" shell pm path "$ROBLOX_PKG" >/dev/null 2>&1; then
    echo "[WARN] Package '$ROBLOX_PKG' does not appear to be installed."
    echo "Continuing setup anyway so RoAndroidShade is active whenever Roblox is launched..."
fi

# 5. Push layer to device
echo "==> Pushing RoAndroidShade layer files to device..."
"$ADB_BIN" shell mkdir -p /data/local/tmp/vulkan/ 2>/dev/null || true
"$ADB_BIN" push "${SO_FILE}" /data/local/tmp/vulkan/libVkLayer_RoShade.so
"$ADB_BIN" push "${JSON_FILE}" /data/local/tmp/vulkan/VkLayer_RoShade.json

# If root is available, also copy to standard debug location
if "$ADB_BIN" shell "su -c 'mkdir -p /data/local/debug/vulkan && cp /data/local/tmp/vulkan/* /data/local/debug/vulkan/'" 2>/dev/null; then
    echo "==> [Root Detected] Installed layer into /data/local/debug/vulkan/"
fi

# 6. Configure Android GPU Debug Layer Settings for Roblox
echo "==> Enabling Vulkan debug layer for Roblox (${ROBLOX_PKG})..."
"$ADB_BIN" shell settings put global enable_gpu_debug_layers 1
"$ADB_BIN" shell settings put global gpu_debug_app "${ROBLOX_PKG}"
"$ADB_BIN" shell settings put global gpu_debug_layers VK_LAYER_RoShade
"$ADB_BIN" shell settings put global gpu_debug_layer_app "${ROBLOX_PKG}"

echo "================================================================"
echo " [SUCCESS] RoAndroidShade activated for Roblox!"
echo "================================================================"
echo "Current GPU Debug Layer Settings on device:"
echo "  enable_gpu_debug_layers: $("$ADB_BIN" shell settings get global enable_gpu_debug_layers | tr -d '\r')"
echo "  gpu_debug_app:           $("$ADB_BIN" shell settings get global gpu_debug_app | tr -d '\r')"
echo "  gpu_debug_layers:        $("$ADB_BIN" shell settings get global gpu_debug_layers | tr -d '\r')"
echo ""
echo "To test:"
echo "  1. Launch Roblox on your phone."
echo "  2. Monitor live layer logs in real time with:"
echo "     adb logcat -s RoShade"
echo ""
echo "To deactivate:"
echo "  Run: ${SCRIPT_DIR}/uninstall_layer.sh"
echo "================================================================"
