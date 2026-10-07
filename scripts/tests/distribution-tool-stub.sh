#!/bin/bash
set -eu
tool="$(basename "$0")"
printf '%s %s\n' "$tool" "$*" >> "$STUB_LOG"
case "$tool" in
security)
    if [ "${STUB_CERT:-developer}" = developer ]; then
        printf '1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "Developer ID Application: Fixture (TEAM)"\n'
    elif [ "$STUB_CERT" = preview ]; then
        printf '1) 52DFDB3AE69296BA6E137CDC8275FD0CF314DA38 "Apple Development: Fixture (TEAM)"\n'
    fi ;;
codesign) [ "${STUB_FAILURE:-}" != signing ] ;;
xcrun)
    case "$*" in
    'notarytool submit '*) [ "${STUB_FAILURE:-}" != notary-submit ]; printf '{"status":"Accepted"}\n' ;;
    'stapler staple '*) [ "${STUB_FAILURE:-}" != staple ] ;;
    'stapler validate '*) [ "${STUB_FAILURE:-}" != staple-validate ] ;;
    *) exit 2 ;;
    esac ;;
plutil)
    case "$2" in
    status) if [ "${STUB_FAILURE:-}" = notary-rejected ]; then printf 'Invalid\n'; else printf 'Accepted\n'; fi ;;
    kind) printf '%s\n' "${STUB_KIND:-quarantined-install-upgrade}" ;;
    sourceSHA) printf '%s\n' "${STUB_SHA:-SOURCE}" ;;
    archiveSHA256) printf '%s\n' "${STUB_DIGEST:-DIGEST}" ;;
    accepted) printf '%s\n' "${STUB_ACCEPTED:-true}" ;;
    *) exit 2 ;;
    esac ;;
spctl) [ "${STUB_FAILURE:-}" != assessment ] ;;
ditto|gh) ;;
*) exit 2 ;;
esac
