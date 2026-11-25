#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
BUNDLE_ID="io.github.jag0710.notion-writer"
APP_NAME="Notion Writer"
DISPLAY_NAME="$APP_NAME"
VERSION="1.2.0"
BUNDLE_VERSION="9"
if [[ $# -eq 1 && "$1" == --trial ]]; then
    BUNDLE_ID="$BUNDLE_ID.trial"
    APP_NAME="Notion Writer Trial"
    DISPLAY_NAME="Notion Writer 試験版"
    BUNDLE_VERSION="10"
elif [[ $# -ne 0 ]]; then
    printf 'Usage: %s [--trial]\n' "$0" >&2
    exit 2
fi
mkdir -p work/build/ModuleCache
if [ ! -f Assets/MenuBarIcon.png ] || [ Assets/WriterIcon.png -nt Assets/MenuBarIcon.png ] || [ scripts/create-menu-bar-icon.swift -nt Assets/MenuBarIcon.png ]; then
    swift -module-cache-path work/build/ModuleCache scripts/create-menu-bar-icon.swift Assets/WriterIcon.png Assets/MenuBarIcon.png
fi
swift build -c release --scratch-path work/build
ASSEMBLY=$(mktemp -d "$PWD/work/app-build.XXXXXX")
trap 'rm -rf "$ASSEMBLY"' EXIT
APP="$ASSEMBLY/$APP_NAME.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Assets/WriterIcon.png "$APP/Contents/Resources/WriterIcon.png"
cp Assets/MenuBarIcon.png "$APP/Contents/Resources/MenuBarIcon.png"
# Only resize for the native icon container. No crop, recolor, mask, shadow or filters.
ICONSET="$PWD/work/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" Assets/WriterIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    retina=$((size * 2))
    sips -z "$retina" "$retina" Assets/WriterIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
cp work/build/release/NotionWriter "$APP/Contents/MacOS/NotionWriter.next"
mv "$APP/Contents/MacOS/NotionWriter.next" "$APP/Contents/MacOS/NotionWriter"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundleName</key><string>$APP_NAME</string>
<key>CFBundleDisplayName</key><string>$DISPLAY_NAME</string>
<key>CFBundleExecutable</key><string>NotionWriter</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUNDLE_VERSION</string>
<key>CFBundleIconFile</key><string>AppIcon.icns</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
if [[ -n "${NOTION_WRITER_SIGN_IDENTITY:-}" ]]; then
    codesign --force --options runtime --timestamp --sign "$NOTION_WRITER_SIGN_IDENTITY" "$APP"
else
    codesign --force --sign - "$APP"
fi
OUTPUT="$PWD/work/$APP_NAME.app"
if [[ -e "$OUTPUT" ]]; then mv "$OUTPUT" "$ASSEMBLY/Previous.app"; fi
mv "$APP" "$OUTPUT"
printf '%s\n' "$OUTPUT"
