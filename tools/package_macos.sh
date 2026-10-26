#!/bin/bash
# Packages pes2017-recomp into a standalone macOS Application Bundle (PES 2017.app)
# Usage: ./tools/package_macos.sh [build_directory] [--dmg]
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

BUILD_DIR="${1:-build-macos}"
if [ ! -d "$BUILD_DIR" ]; then
    if [ -d "build" ]; then
        BUILD_DIR="build"
    else
        echo "Error: Build directory '$BUILD_DIR' not found."
        echo "Please build first using ./build-macos.sh"
        exit 1
    fi
fi

APP_NAME="PES 2017.app"
APP_DIR="$ROOT/$APP_NAME"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

echo "==> Creating macOS App Bundle: $APP_NAME"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

# 1. Copy launcher executable
LAUNCHER_BIN=""
for candidate in "$BUILD_DIR/launcher/pes17-launcher" "$BUILD_DIR/pes17-launcher"; do
    if [ -f "$candidate" ]; then
        LAUNCHER_BIN="$candidate"
        break
    fi
done

if [ -z "$LAUNCHER_BIN" ]; then
    echo "Error: pes17-launcher executable not found in $BUILD_DIR"
    exit 1
fi

echo "==> Copying launcher executable: $LAUNCHER_BIN"
cp "$LAUNCHER_BIN" "$MACOS_DIR/pes17-launcher"
chmod +x "$MACOS_DIR/pes17-launcher"

# 2. Copy game binary (pes17-sp) if available
if [ -f "$BUILD_DIR/pes17-sp" ]; then
    echo "==> Copying game executable: $BUILD_DIR/pes17-sp"
    cp "$BUILD_DIR/pes17-sp" "$MACOS_DIR/pes17-sp"
    chmod +x "$MACOS_DIR/pes17-sp"
fi

# 3. Create launcher script as entrypoint to setup environment (MoltenVK, Vulkan)
cat << 'EOF' > "$MACOS_DIR/PES2017_Runner"
#!/bin/bash
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

# Prefer Homebrew or Vulkan SDK MoltenVK if available
if [ -z "${VK_ICD_FILENAMES:-}" ] && [ -z "${VK_DRIVER_FILES:-}" ]; then
    for icd in \
        /opt/homebrew/share/vulkan/icd.d/MoltenVK_icd.json \
        /usr/local/share/vulkan/icd.d/MoltenVK_icd.json \
        "$VULKAN_SDK/share/vulkan/icd.d/MoltenVK_icd.json"
    do
        if [ -f "$icd" ]; then
            export VK_DRIVER_FILES="$icd"
            break
        fi
    done
fi

exec "$DIR/pes17-launcher" "$@"
EOF
chmod +x "$MACOS_DIR/PES2017_Runner"

# 4. Generate Info.plist
cat << 'EOF' > "$CONTENTS_DIR/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>PES 2017</string>
    <key>CFBundleExecutable</key>
    <string>PES2017_Runner</string>
    <key>CFBundleIconFile</key>
    <string>PES2017</string>
    <key>CFBundleIdentifier</key>
    <string>com.konami.pes2017.recomp</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>PES 2017</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>11.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
    <key>NSRequiresAquaSystemAppearance</key>
    <false/>
</dict>
</plist>
EOF

# 5. Icon generation
if command -v sips >/dev/null 2>&1 && command -v iconutil >/dev/null 2>&1 && [ -f "launcher/icon/launcher.bmp" ]; then
    echo "==> Generating PES2017.icns..."
    ICONSET=$(mktemp -d)/PES2017.iconset
    mkdir -p "$ICONSET"
    sips -s format png launcher/icon/launcher.bmp --out "$ICONSET/icon_512x512@2x.png" >/dev/null 2>&1 || true
    if [ -f "$ICONSET/icon_512x512@2x.png" ]; then
        sips -z 16 16     "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_16x16.png" >/dev/null 2>&1
        sips -z 32 32     "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_16x16@2x.png" >/dev/null 2>&1
        sips -z 32 32     "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_32x32.png" >/dev/null 2>&1
        sips -z 64 64     "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_32x32@2x.png" >/dev/null 2>&1
        sips -z 128 128   "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_128x128.png" >/dev/null 2>&1
        sips -z 256 256   "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_128x128@2x.png" >/dev/null 2>&1
        sips -z 256 256   "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_256x256.png" >/dev/null 2>&1
        sips -z 512 512   "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_256x256@2x.png" >/dev/null 2>&1
        sips -z 512 512   "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_512x512.png" >/dev/null 2>&1
        iconutil -c icns "$ICONSET" -o "$RESOURCES_DIR/PES2017.icns" >/dev/null 2>&1 || true
    fi
    rm -rf "$(dirname "$ICONSET")"
fi

# Fallback: copy BMP as icon reference if icns wasn't generated
if [ ! -f "$RESOURCES_DIR/PES2017.icns" ] && [ -f "launcher/icon/launcher.bmp" ]; then
    cp "launcher/icon/launcher.bmp" "$RESOURCES_DIR/PES2017.bmp"
fi

echo "==> Successfully created $APP_NAME!"

# 6. Optional DMG creation on macOS
if [ "${2:-}" = "--dmg" ] && command -v hdiutil >/dev/null 2>&1; then
    DMG_NAME="PES_2017_macOS.dmg"
    echo "==> Creating disk image: $DMG_NAME..."
    rm -f "$DMG_NAME"
    hdiutil create -volname "PES 2017" -srcfolder "$APP_DIR" -ov -format UDZO "$DMG_NAME"
    echo "==> Created $DMG_NAME!"
fi
