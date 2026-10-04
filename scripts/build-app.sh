#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${1:-release}"
case "$CONFIGURATION" in debug|release) ;; *) printf 'Usage: bash scripts/build-app.sh [debug|release]\n' >&2; exit 2 ;; esac
swift build --package-path "$ROOT" -c "$CONFIGURATION" --product Arpeggio
BIN="$(swift build --package-path "$ROOT" -c "$CONFIGURATION" --show-bin-path)"
APP="$ROOT/dist/Soulseek-Arpeggio.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$ROOT/dist/AppIcon.iconset"
cp "$BIN/Arpeggio" "$APP/Contents/MacOS/Arpeggio.next"
mv "$APP/Contents/MacOS/Arpeggio.next" "$APP/Contents/MacOS/Arpeggio"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
ICON_TOOL="$ROOT/.build/arpeggio-icon"
swiftc -O "$ROOT/scripts/icon/main.swift" "$ROOT/Sources/Arpeggio/ArpeggioMark.swift" -o "$ICON_TOOL"
"$ICON_TOOL" "$ROOT/dist/AppIcon.iconset"
iconutil -c icns "$ROOT/dist/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
IDENTITY="${ARPEGGIO_SIGNING_IDENTITY:-$(security find-identity -p codesigning -v 2>/dev/null | awk -F'"' '/Apple Development|Developer ID Application/ { print $2; exit }')}"
codesign --force --timestamp=none --sign "${IDENTITY:--}" "$APP"
printf 'Signed with %s\n' "${IDENTITY:-ad-hoc identity}"
printf 'Built %s\n' "$APP"
if [ "$CONFIGURATION" = release ]; then
    VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
    ARCHIVE="$ROOT/dist/Soulseek-Arpeggio-$VERSION.zip"
    rm -f "$ARCHIVE"
    ditto -c -k --keepParent "$APP" "$ARCHIVE"
    printf 'Archived %s\n' "$ARCHIVE"
fi
