#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/project/scripts" "$TMP/project/dist" "$TMP/project/Resources"
for command in git security swift unzip ditto plutil gh; do
    cp "$ROOT/scripts/tests/release-orchestration-tool-stub.sh" "$TMP/bin/$command"
    chmod 700 "$TMP/bin/$command"
done
for script in build-app.sh verify-artifact.sh; do cp "$ROOT/scripts/tests/release-orchestration-fixture-action.sh" "$TMP/project/scripts/$script"; done
export PATH="$TMP/bin:$PATH" STUB_ROOT="$TMP/project" STUB_LOG="$TMP/log"
export SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa OTHER_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
export LIB="$ROOT/scripts/lib/distribution.sh" ORCHESTRATION="$ROOT/scripts/lib/release-orchestration.sh" FUNCTIONS="$ROOT/scripts/tests/release-orchestration-fixture-functions.sh"
export ARPEGGIO_SIGNING_IDENTITY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA ARPEGGIO_NOTARY_PROFILE=fixture
export ARPEGGIO_QUARANTINE_RECEIPT="$TMP/quarantine.json" ARPEGGIO_NETWORK_RECEIPT="$TMP/network.json"
touch "$ARPEGGIO_QUARANTINE_RECEIPT" "$ARPEGGIO_NETWORK_RECEIPT"
count=0
reset_case() {
    rm -f "$STUB_ROOT/dirty" "$STUB_ROOT/head-changed"
    : > "$STUB_LOG"
    printf 'ARCHIVE' > "$STUB_ROOT/dist/Soulseek-Arpeggio-$VERSION.zip"
    EXPECTED_DIGEST="$(shasum -a 256 "$STUB_ROOT/dist/Soulseek-Arpeggio-$VERSION.zip" | cut -d ' ' -f1)"
    export EXPECTED_DIGEST
}
invoke() { bash -eu -c 'source "$LIB"; source "$ORCHESTRATION"; source "$FUNCTIONS"; run_release "$ACTION" "$MODE" "$SHA" "$STUB_ROOT"'; }
must_fail() {
    reset_case
    if invoke; then printf 'Expected release orchestration failure.\n' >&2; exit 1; fi
    if grep -q '^gh release create' "$STUB_LOG"; then printf 'Unsafe publication reached gh.\n' >&2; exit 1; fi
    count=$((count+1))
}
export ACTION=publish MODE=preview VERSION=0.6.0-rc.1
STUB_MUTATE=verify-dirty must_fail
STUB_MUTATE=verify-head must_fail
STUB_MUTATE=verify-archive must_fail
STUB_SIGNED_SHA="$OTHER_SHA" must_fail
STUB_SIGNED_TREE=uncommitted must_fail
STUB_PUBLIC_MAIN="$OTHER_SHA" must_fail
STUB_TAG="$OTHER_SHA" must_fail
STUB_TAG="$SHA" STUB_PEELED_TAG="$OTHER_SHA" must_fail
export ACTION=prepare MODE=production VERSION=0.6.0
STUB_MUTATE=tests-dirty must_fail
STUB_MUTATE=verify-head must_fail
export ACTION=publish
STUB_RECEIPT_DIGEST=wrong must_fail
STUB_SIGNED_SHA="$OTHER_SHA" must_fail
STUB_SIGNED_TREE=uncommitted must_fail
reset_case
invoke
[ "$(shasum -a 256 "$STUB_ROOT/dist/Soulseek-Arpeggio-$VERSION.zip" | cut -d ' ' -f1)" = "$EXPECTED_DIGEST" ]
if grep -Eq '^swift |BUILD_SIGN_NOTARIZE|notarytool submit|codesign --force' "$STUB_LOG"; then printf 'Production publish rebuilt or resigned accepted artifact.\n' >&2; exit 1; fi
grep -q '^gh release create v0.6.0 ' "$STUB_LOG"
count=$((count+1))
export MODE=preview VERSION=0.6.0-rc.1
reset_case
invoke
grep -q -- '--repo Ashref-dev/soulseek-client-mac' "$STUB_LOG"
grep -q -- '--prerelease' "$STUB_LOG"
if grep -q 'ls-remote origin' "$STUB_LOG"; then printf 'Queried arbitrary origin instead of publication repository.\n' >&2; exit 1; fi
count=$((count+1))
printf 'PASS: %d full release orchestration cases; mutation, signed provenance, public repository and peeled-tag gates fail closed; production publication preserves accepted archive without rebuild/sign/notary. All positive production fixtures are stubs, not real acceptance evidence.\n' "$count"
