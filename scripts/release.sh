#!/bin/bash
# Builds, tests and publishes the version in Resources/Info.plist as a GitHub release.
# The archive is what the in-app updater downloads, so it must be signed with the same identity as earlier releases.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
NOTES="${1:-}"
swift test --package-path "$ROOT"
bash "$ROOT/scripts/build-app.sh" release
codesign --verify --deep --strict "$ROOT/dist/Arpeggio.app"
if codesign -dv "$ROOT/dist/Arpeggio.app" 2>&1 | grep -q 'Signature=adhoc'; then
    printf 'Refusing to publish an ad-hoc signed build: the updater could not verify it.\n' >&2
    exit 1
fi
ARGS=(--title "Arpeggio $VERSION")
if [ -n "$NOTES" ]; then ARGS+=(--notes-file "$NOTES"); else ARGS+=(--generate-notes); fi
gh release create "v$VERSION" "$ROOT/dist/Arpeggio-$VERSION.zip" "${ARGS[@]}"
