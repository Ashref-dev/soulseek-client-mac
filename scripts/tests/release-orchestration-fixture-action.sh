#!/bin/bash
set -eu
case "$(basename "$0")" in
build-app.sh)
    printf 'BUILD_SIGN_NOTARIZE\n' >> "$STUB_LOG"
    mkdir -p "$STUB_ROOT/dist/Soulseek-Arpeggio.app/Contents"
    touch "$STUB_ROOT/dist/Soulseek-Arpeggio.app/Contents/Info.plist"
    printf 'ARCHIVE' > "$STUB_ROOT/dist/Soulseek-Arpeggio-$VERSION.zip" ;;
verify-artifact.sh)
    printf 'VERIFY_EXISTING_ARTIFACT %s\n' "$*" >> "$STUB_LOG"
    case "${STUB_MUTATE:-}" in
    verify-dirty) touch "$STUB_ROOT/dirty" ;;
    verify-head) touch "$STUB_ROOT/head-changed" ;;
    verify-archive) printf 'MUTATED' > "$STUB_ROOT/dist/Soulseek-Arpeggio-$VERSION.zip" ;;
    esac ;;
*) exit 2 ;;
esac
