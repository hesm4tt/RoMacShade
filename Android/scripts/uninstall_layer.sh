#!/bin/bash
#
# Uninstaller / Reset script for RoAndroidShade (VK_LAYER_RoShade)
# Restores Android Vulkan GPU settings to default
#

set -e

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
    exit 1
fi

echo "==> Resetting Android GPU debug layer settings..."
"$ADB_BIN" shell settings delete global enable_gpu_debug_layers 2>/dev/null || true
"$ADB_BIN" shell settings delete global gpu_debug_app 2>/dev/null || true
"$ADB_BIN" shell settings delete global gpu_debug_layers 2>/dev/null || true
"$ADB_BIN" shell settings delete global gpu_debug_layer_app 2>/dev/null || true

# Optional cleanup of tmp files
"$ADB_BIN" shell rm -rf /data/local/tmp/vulkan 2>/dev/null || true

echo "================================================================"
echo " [SUCCESS] RoAndroidShade deactivated! Roblox is back to default."
echo "================================================================"
