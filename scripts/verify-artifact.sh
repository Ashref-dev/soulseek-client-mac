#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/lib/distribution.sh"
MODE="${1:---invalid}"
MODE="${MODE#--}"
APP="${2:-}"
require_mode "$MODE"
[ -d "$APP" ] && [ ! -L "$APP" ] || fail 'An actual app bundle is required.'
INFO="$APP/Contents/Info.plist"
[ "$(plist_value "$INFO" CFBundleIdentifier)" = tn.ashref.arpeggio ] || fail 'Wrong bundle identifier.'
SHORT="$(plist_value "$INFO" CFBundleShortVersionString)"
VERSION="$(plist_value "$INFO" ArpeggioReleaseVersion)"
[[ "$SHORT" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'Apple short version must be numeric.'
[[ "$VERSION" = "$SHORT" || "$VERSION" = "$SHORT-"* ]] || fail 'Semantic release core must match the Apple short version.'
[ "$(plist_value "$INFO" LSMinimumSystemVersion)" = 27.0 ] || fail 'Supported platform must remain macOS 27+.'
BIN="$APP/Contents/MacOS/$(plist_value "$INFO" CFBundleExecutable)"
[ "$(lipo -archs "$BIN")" = arm64 ] || fail 'Only the tested Apple Silicon architecture is supported.'
codesign --verify --deep --strict "$APP"
DETAIL="$(codesign -dv --verbose=4 "$APP" 2>&1)"
codesign -dr - "$APP" 2>&1
if [ "$MODE" = production ]; then
    [ "$(plist_value "$INFO" ArpeggioSourceTreeState)" = clean ] || fail 'Production artifact must come from a committed clean source tree.'
    [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'Stable production version required.'
    [[ "$DETAIL" = *'Authority=Developer ID Application:'* && "$DETAIL" = *runtime* && "$DETAIL" = *Timestamp=* ]] || fail 'Developer ID, hardened runtime and timestamp are required.'
    xcrun stapler validate "$APP"
    spctl --assess --type execute --verbose=4 "$APP"
else
    [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+- ]] || fail 'Preview version must be prerelease.'
    [[ "$DETAIL" = *'Authority=Apple Development:'* ]] || fail 'Preview must be development signed.'
    CERTDIR="$(mktemp -d)"
    trap 'rm -rf "$CERTDIR"' EXIT
    codesign -d --extract-certificates="$CERTDIR/cert" "$APP"
    CERTSHA="$(shasum -a 1 "$CERTDIR/cert0" | cut -d ' ' -f1 | tr '[:lower:]' '[:upper:]')"
    [ "$CERTSHA" = "$PREVIEW_IDENTITY" ] || fail 'Preview certificate does not match pinned owner identity.'
    if spctl --assess --type execute --verbose=4 "$APP"; then printf 'Preview assessment accepted locally; no clean-machine acceptance claim.\n'; else printf 'Preview Gatekeeper rejected, as expected for unnotarized development signing.\n'; fi
fi
printf 'mode=%s version=%s shortVersion=%s build=%s source=%s sourceTree=%s architecture=arm64 minimumOS=27.0\n' "$MODE" "$VERSION" "$SHORT" "$(plist_value "$INFO" CFBundleVersion)" "$(plist_value "$INFO" ArpeggioSourceRevision)" "$(plist_value "$INFO" ArpeggioSourceTreeState)"
shasum -a 256 "$BIN"
