#!/bin/bash
PREVIEW_IDENTITY=52DFDB3AE69296BA6E137CDC8275FD0CF314DA38
fail() { printf '%s\n' "$*" >&2; exit 1; }
require_mode() { case "$1" in preview|production) ;; *) fail 'Explicit preview or production mode required.' ;; esac; }
require_identity() {
    local mode="$1" identities
    require_mode "$mode"
    identities="$(security find-identity -p codesigning -v)"
    if [ "$mode" = preview ]; then
        IDENTITY="$PREVIEW_IDENTITY"
        [[ "$identities" =~ $PREVIEW_IDENTITY[[:space:]]+\"Apple\ Development ]] || fail 'Pinned Apple Development certificate unavailable.'
        [ -z "${ARPEGGIO_SIGNING_IDENTITY:-}" ] || [ "$ARPEGGIO_SIGNING_IDENTITY" = "$IDENTITY" ] || fail 'Preview identity must match the pinned certificate.'
    else
        IDENTITY="${ARPEGGIO_SIGNING_IDENTITY:-}"
        [[ "$IDENTITY" =~ ^[A-Fa-f0-9]{40}$ ]] || fail 'Production requires an explicit Developer ID certificate SHA-1.'
        [[ "$identities" =~ $IDENTITY[[:space:]]+\"Developer\ ID\ Application: ]] || fail 'Explicit production certificate is not a valid Developer ID Application identity.'
        [ -n "${ARPEGGIO_NOTARY_PROFILE:-}" ] || fail 'Production requires an existing notarytool profile.'
    fi
}
plist_value() { /usr/libexec/PlistBuddy -c "Print :$2" "$1"; }
require_receipt() {
    local file="$1" kind="$2" sha="$3" digest="$4"
    [ -f "$file" ] && [ ! -L "$file" ] || fail "Missing $kind acceptance receipt."
    [ "$(plutil -extract kind raw -o - "$file")" = "$kind" ] || fail 'Wrong acceptance receipt kind.'
    [ "$(plutil -extract sourceSHA raw -o - "$file")" = "$sha" ] || fail 'Acceptance receipt source mismatch.'
    [ "$(plutil -extract archiveSHA256 raw -o - "$file")" = "$digest" ] || fail 'Acceptance receipt artifact mismatch.'
    [ "$(plutil -extract accepted raw -o - "$file")" = true ] || fail 'Acceptance receipt does not accept this artifact.'
}
production_sign_and_notarize() {
    local app="$1" output="$2"
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$app"
    ditto -c -k --norsrc --keepParent "$app" "$output/notary-submission.zip"
    xcrun notarytool submit "$output/notary-submission.zip" --keychain-profile "$ARPEGGIO_NOTARY_PROFILE" --wait --timeout 20m --output-format json > "$output/notary-result.json"
    [ "$(plutil -extract status raw -o - "$output/notary-result.json")" = Accepted ] || fail 'Notarization was not accepted.'
    xcrun stapler staple "$app"
    xcrun stapler validate "$app"
    spctl --assess --type execute --verbose=4 "$app"
}
