#!/bin/bash
#
# Copyright (c) 2026 MacShade Authors. All Rights Reserved.
# PROPRIETARY AND CONFIDENTIAL.
# UNAUTHORIZED COPYING, REVERSE ENGINEERING, REBRANDING, OR DISTRIBUTION IS STRICTLY PROHIBITED.
#
set -euo pipefail
cd "$(dirname "$0")/.."

DMG_NAME="MacShade-v0.0.1.dmg"
OUTPUT_DMG="build/$DMG_NAME"
STAGE_DIR="/tmp/macshade_dmg_stage_$$"

echo "=== Building $DMG_NAME ==="

if [[ ! -d "build/MacShade.app" ]]; then
    echo "Error: build/MacShade.app not found. Run ./build.sh first." >&2
    exit 1
fi

rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"

echo "Copying MacShade.app to stage..."
ditto "build/MacShade.app" "$STAGE_DIR/MacShade.app"

echo "Copying documentation to stage..."
cp README.html "$STAGE_DIR/README.html"

echo "Creating Applications symlink..."
ln -s /Applications "$STAGE_DIR/Applications"

cat > "$STAGE_DIR/README.txt" <<'EOF'
MacShade v0.0.1 — ReShade & FX Shaders on macOS Metal for Roblox

============================================================
INSTALLATION:
============================================================
1. Drag MacShade.app into your Applications folder.
2. Open MacShade from your Applications folder.

============================================================
macOS GATEKEEPER NOTICE (NOT A VIRUS):
============================================================
MacShade is 100% clean, safe, and contains NO malware.

Because MacShade is an independent community project developed
outside the Mac App Store without an Apple Developer ID
subscription ($99/yr), macOS Gatekeeper displays a standard
warning on first launch:
"Apple cannot check it for malicious software" or
"Cannot verify the developer".

HOW TO OPEN (First time only):
• Method 1 (Easiest):
  Right-click (or Control-click) MacShade.app in your
  Applications folder and select "Open", then click "Open".
• Method 2:
  Go to System Settings -> Privacy & Security -> Security,
  and click "Open Anyway".
• Method 3 (Terminal):
  xattr -cr /Applications/MacShade.app

============================================================
USAGE:
============================================================
• Click "Launch Roblox with MacShade" in the MacShade window.
• Once in-game:
    - Click the floating circular 'M' button or press ⌘E to open the effects overlay.
    - Press ⌘B to quickly toggle effects on and off.
    - Drag the circular 'M' button anywhere on screen to reposition it.
    - Use the Quality toggle in the overlay header to cycle between 100% (FQ), 75%, and 50% resolution scaling.

Enjoy your enhanced Roblox visuals on macOS!
EOF

rm -f "$OUTPUT_DMG"
echo "Creating compressed DMG..."
hdiutil create -volname "MacShade" -srcfolder "$STAGE_DIR" -ov -format UDZO "$OUTPUT_DMG"

echo "Signing DMG..."
codesign --force --sign - "$OUTPUT_DMG"

rm -rf "$STAGE_DIR"

echo "=== Successfully built $OUTPUT_DMG ==="
ls -lh "$OUTPUT_DMG"
