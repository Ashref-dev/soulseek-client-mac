#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir "$TMP/bin"
for command in security codesign xcrun plutil spctl ditto gh; do
    cp "$ROOT/scripts/tests/distribution-tool-stub.sh" "$TMP/bin/$command"
    chmod 700 "$TMP/bin/$command"
done
export PATH="$TMP/bin:$PATH" STUB_LOG="$TMP/log"
export ARPEGGIO_SIGNING_IDENTITY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA ARPEGGIO_NOTARY_PROFILE=fixture
export LIB="$ROOT/scripts/lib/distribution.sh" TMP
count=0
must_fail() {
    : > "$STUB_LOG"
    if bash -eu -c "$1"; then printf 'Expected gate failure: %s\n' "$1" >&2; exit 1; fi
    if grep -q '^gh ' "$STUB_LOG"; then printf 'Failure reached publication.\n' >&2; exit 1; fi
    count=$((count+1))
}
must_fail 'source "$LIB"; require_mode ""; gh release create'
must_fail 'source "$LIB"; unset ARPEGGIO_SIGNING_IDENTITY; require_identity production; gh release create'
must_fail 'source "$LIB"; unset ARPEGGIO_NOTARY_PROFILE; require_identity production; gh release create'
STUB_CERT=none must_fail 'source "$LIB"; require_identity production; gh release create'
STUB_CERT=preview must_fail 'source "$LIB"; require_identity preview; gh release create'
STUB_CERT=developer must_fail 'source "$LIB"; require_identity preview; gh release create'
for stage in signing notary-submit notary-rejected staple staple-validate assessment; do
    STUB_FAILURE="$stage" must_fail 'source "$LIB"; require_identity production; production_sign_and_notarize fixture.app "$TMP"; gh release create'
done
must_fail 'source "$LIB"; require_receipt "$TMP/absent" quarantined-install-upgrade SOURCE DIGEST; gh release create'
touch "$TMP/receipt"
STUB_SHA=OTHER must_fail 'source "$LIB"; require_receipt "$TMP/receipt" quarantined-install-upgrade SOURCE DIGEST; gh release create'
STUB_DIGEST=OTHER must_fail 'source "$LIB"; require_receipt "$TMP/receipt" quarantined-install-upgrade SOURCE DIGEST; gh release create'
STUB_ACCEPTED=false must_fail 'source "$LIB"; require_receipt "$TMP/receipt" quarantined-install-upgrade SOURCE DIGEST; gh release create'
STUB_KIND=other must_fail 'source "$LIB"; require_receipt "$TMP/receipt" quarantined-install-upgrade SOURCE DIGEST; gh release create'
STUB_CERT=preview ARPEGGIO_SIGNING_IDENTITY=52DFDB3AE69296BA6E137CDC8275FD0CF314DA38 bash -eu -c 'source "$LIB"; require_identity preview'
count=$((count+1))
printf 'PASS: %d distribution gate cases; negative stages never reached gh. No real Developer ID/notarization success asserted.\n' "$count"
