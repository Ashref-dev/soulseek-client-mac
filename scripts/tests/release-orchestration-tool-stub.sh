#!/bin/bash
set -eu
tool="$(basename "$0")"
printf '%s %s\n' "$tool" "$*" >> "$STUB_LOG"
case "$tool" in
git)
    case "$3" in
    rev-parse) if [ -f "$STUB_ROOT/head-changed" ]; then printf '%s\n' "$OTHER_SHA"; else printf '%s\n' "$SHA"; fi ;;
    status) if [ -f "$STUB_ROOT/dirty" ]; then printf ' M Sources/changed.swift\n'; fi ;;
    ls-remote)
        [ "$4" = https://github.com/Ashref-dev/soulseek-client-mac.git ] || { printf 'Wrong repository query\n' >&2; exit 1; }
        printf '%s\trefs/heads/main\n' "${STUB_PUBLIC_MAIN:-$SHA}"
        if [ -n "${STUB_TAG:-}" ]; then printf '%s\trefs/tags/v%s\n' "$STUB_TAG" "$VERSION"; fi
        if [ -n "${STUB_PEELED_TAG:-}" ]; then printf '%s\trefs/tags/v%s^{}\n' "$STUB_PEELED_TAG" "$VERSION"; fi ;;
    *) exit 2 ;;
    esac ;;
security) printf '1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "Developer ID Application: Fixture (TEAM)"\n' ;;
swift) if [ "${STUB_MUTATE:-}" = tests-dirty ]; then touch "$STUB_ROOT/dirty"; fi ;;
unzip)
    case "$2" in
    -1) printf 'Soulseek-Arpeggio.app/Contents/Info.plist\n' ;;
    -l) printf '%s\n' '-rw-r--r-- 2.1 unx 5 bX 5 stor 26-Oct-06 23:52 Soulseek-Arpeggio.app/Contents/Info.plist' ;;
    *) exit 2 ;;
    esac ;;
ditto) mkdir -p "$5/Soulseek-Arpeggio.app/Contents"; touch "$5/Soulseek-Arpeggio.app/Contents/Info.plist" ;;
plutil)
    case "$2" in
    kind) case "$*" in *network.json*) printf 'independent-network-transfer\n';; *) printf 'quarantined-install-upgrade\n';; esac ;;
    sourceSHA) printf '%s\n' "$SHA" ;;
    archiveSHA256) printf '%s\n' "${STUB_RECEIPT_DIGEST:-$EXPECTED_DIGEST}" ;;
    accepted) printf 'true\n' ;;
    *) exit 2 ;;
    esac ;;
gh) ;;
*) exit 2 ;;
esac
