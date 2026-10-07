#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${1:-release}"
MODE="${2:-preview}"
source "$ROOT/scripts/lib/distribution.sh"
require_identity "$MODE"
case "$CONFIGURATION" in debug|release) ;; *) printf 'Usage: bash scripts/build-app.sh [debug|release]\n' >&2; exit 2 ;; esac
swift build --package-path "$ROOT" -c "$CONFIGURATION" --arch arm64 --product Arpeggio
BIN="$(swift build --package-path "$ROOT" -c "$CONFIGURATION" --show-bin-path)"
APP="$ROOT/dist/Soulseek-Arpeggio.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$ROOT/dist/AppIcon.iconset"
cp "$BIN/Arpeggio" "$APP/Contents/MacOS/Arpeggio.next"
mv "$APP/Contents/MacOS/Arpeggio.next" "$APP/Contents/MacOS/Arpeggio"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
SHA="${ARPEGGIO_SOURCE_SHA:-$(GIT_MASTER=1 git -C "$ROOT" rev-parse HEAD)}"
[[ "$SHA" =~ ^[a-f0-9]{40}$ ]] || fail 'A full source SHA is required.'
/usr/libexec/PlistBuddy -c "Add :ArpeggioSourceRevision string $SHA" "$APP/Contents/Info.plist"
TREE_STATE=clean
if [ -n "$(GIT_MASTER=1 git -C "$ROOT" status --porcelain)" ]; then TREE_STATE=uncommitted; fi
/usr/libexec/PlistBuddy -c "Add :ArpeggioSourceTreeState string $TREE_STATE" "$APP/Contents/Info.plist"
ICON_TOOL="$ROOT/.build/arpeggio-icon"
swiftc -O "$ROOT/scripts/icon/main.swift" "$ROOT/Sources/Arpeggio/ArpeggioMark.swift" -o "$ICON_TOOL"
"$ICON_TOOL" "$ROOT/dist/AppIcon.iconset"
iconutil -c icns "$ROOT/dist/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
if [ "$MODE" = production ]; then
    production_sign_and_notarize "$APP" "$ROOT/dist"
else
    codesign --force --timestamp=none --sign "$IDENTITY" "$APP"
fi
codesign --verify --deep --strict "$APP"
printf 'Signed %s with %s\n' "$MODE" "$IDENTITY"
printf 'Built %s\n' "$APP"
if [ "$CONFIGURATION" = release ]; then
    VERSION="$(plist_value "$APP/Contents/Info.plist" ArpeggioReleaseVersion)"
    ARCHIVE="$ROOT/dist/Soulseek-Arpeggio-$VERSION.zip"
    rm -f "$ARCHIVE"
    ditto -c -k --norsrc --keepParent "$APP" "$ARCHIVE"
    printf 'Archived %s\n' "$ARCHIVE"
fi
