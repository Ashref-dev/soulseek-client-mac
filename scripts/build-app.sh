#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${1:-release}"
case "$CONFIGURATION" in debug|release) ;; *) printf 'Usage: bash scripts/build-app.sh [debug|release]\n' >&2; exit 2 ;; esac
swift build --package-path "$ROOT" -c "$CONFIGURATION" --product Arpeggio
BIN="$(swift build --package-path "$ROOT" -c "$CONFIGURATION" --show-bin-path)"
APP="$ROOT/dist/Arpeggio.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$ROOT/dist/AppIcon.iconset"
cp "$BIN/Arpeggio" "$APP/Contents/MacOS/Arpeggio.next"
mv "$APP/Contents/MacOS/Arpeggio.next" "$APP/Contents/MacOS/Arpeggio"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
swift "$ROOT/scripts/render-icon.swift" "$ROOT/dist/AppIcon.iconset"
iconutil -c icns "$ROOT/dist/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign "${ARPEGGIO_SIGNING_IDENTITY:--}" "$APP"
printf 'Built %s\n' "$APP"
