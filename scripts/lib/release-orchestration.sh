#!/bin/bash
PUBLIC_REPOSITORY=Ashref-dev/soulseek-client-mac
PUBLIC_REMOTE=https://github.com/Ashref-dev/soulseek-client-mac.git

assert_release_source() {
    local root="$1" sha="$2" version="$3" refs main tag peeled
    [ "$(GIT_MASTER=1 git -C "$root" rev-parse HEAD)" = "$sha" ] || fail 'Release HEAD changed or does not match target.'
    [ -z "$(GIT_MASTER=1 git -C "$root" status --porcelain)" ] || fail 'Release source tree must remain committed and clean.'
    refs="$(GIT_MASTER=1 git -C "$root" ls-remote "$PUBLIC_REMOTE" refs/heads/main "refs/tags/v$version" "refs/tags/v$version^{}")"
    main="$(printf '%s\n' "$refs" | awk '$2 == "refs/heads/main" { print $1 }')"
    [ "$main" = "$sha" ] || fail 'Target is not the exact main SHA in the actual public publication repository.'
    tag="$(printf '%s\n' "$refs" | awk -v ref="refs/tags/v$version" '$2 == ref { print $1 }')"
    peeled="$(printf '%s\n' "$refs" | awk -v ref="refs/tags/v$version^{}" '$2 == ref { print $1 }')"
    if [ -n "$peeled" ]; then
        [ -n "$tag" ] && [ "$peeled" = "$sha" ] || fail 'Existing annotated release tag targets a different source SHA.'
    elif [ -n "$tag" ]; then
        [ "$tag" = "$sha" ] || fail 'Existing release tag targets a different source SHA.'
    fi
}

assert_artifact_source() {
    local info="$1/Contents/Info.plist" sha="$2" version="$3"
    [ "$(plist_value "$info" ArpeggioSourceRevision)" = "$sha" ] || fail 'Signed artifact source SHA differs from publication target.'
    [ "$(plist_value "$info" ArpeggioSourceTreeState)" = clean ] || fail 'Signed artifact source tree is not clean.'
    [ "$(plist_value "$info" ArpeggioReleaseVersion)" = "$version" ] || fail 'Signed artifact release version differs from tag.'
}

archive_digest() { shasum -a 256 "$1" | cut -d ' ' -f1; }

validate_release_archive() {
    local archive="$1" entries listing
    [ -f "$archive" ] && [ ! -L "$archive" ] || fail 'Prepared archive missing or symbolic link.'
    [ "$(wc -c < "$archive")" -le 134217728 ] || fail 'Release archive exceeds 128 MiB.'
    entries="$(unzip -Z -1 "$archive")"
    printf '%s\n' "$entries" | awk '
      !/^Soulseek-Arpeggio\.app\// || /(^|\/)\.\.?($|\/)/ || /\/\// || /[^A-Za-z0-9_.\/-]/ { exit 1 }
      { key=tolower($0); if (seen[key]++) exit 1; count++ }
      END { if (count < 1 || count > 5000) exit 1 }' || fail 'Unsafe or ambiguous release archive paths.'
    listing="$(unzip -Z -l "$archive")"
    printf '%s\n' "$listing" | awk '
      /^[dlcbps?-]/ { if (!/^[d-]/ || $4 !~ /^[0-9]+$/) exit 1; count++; total += $4 }
      END { if (count < 1 || count > 5000 || total > 536870912) exit 1 }' || fail 'Release archive links/types/expanded size are unsafe.'
}

run_release() (
    set -euo pipefail
    action="$1" mode="$2" sha="$3" root="$4" notes="${5:-}"
    require_mode "$mode"
    case "$action" in prepare|publish) ;; *) fail 'Explicit prepare or publish action required.' ;; esac
    [[ "$sha" =~ ^[a-f0-9]{40}$ ]] || fail 'A full public main source SHA is required.'
    version="$(plist_value "$root/Resources/Info.plist" ArpeggioReleaseVersion)"
    if [ "$mode" = preview ]; then
        [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+-[A-Za-z0-9.-]+$ ]] || fail 'Preview requires a semantic prerelease version.'
    else
        [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'Production requires a stable numeric release version.'
    fi
    assert_release_source "$root" "$sha" "$version"
    archive="$root/dist/Soulseek-Arpeggio-$version.zip"
    if [ "$action" = prepare ]; then
        require_identity "$mode"
        swift test --package-path "$root"
        ARPEGGIO_SOURCE_SHA="$sha" bash "$root/scripts/build-app.sh" release "$mode"
        bash "$root/scripts/verify-artifact.sh" "--$mode" "$root/dist/Soulseek-Arpeggio.app"
        assert_artifact_source "$root/dist/Soulseek-Arpeggio.app" "$sha" "$version"
        assert_release_source "$root" "$sha" "$version"
        printf 'Prepared immutable acceptance candidate: %s\nSHA256=%s\n' "$archive" "$(archive_digest "$archive")"
        exit 0
    fi
    validate_release_archive "$archive"
    digest="$(archive_digest "$archive")"
    if [ "$mode" = production ]; then
        require_receipt "${ARPEGGIO_QUARANTINE_RECEIPT:-}" quarantined-install-upgrade "$sha" "$digest"
        require_receipt "${ARPEGGIO_NETWORK_RECEIPT:-}" independent-network-transfer "$sha" "$digest"
    fi
    snapshot="$(mktemp -d)"
    chmod 700 "$snapshot"
    trap 'rm -rf "$snapshot"' EXIT
    upload="$snapshot/Soulseek-Arpeggio-$version.zip"
    cp "$archive" "$upload"
    chmod 600 "$upload"
    [ "$(archive_digest "$upload")" = "$digest" ] || fail 'Archive changed while copying immutable publication snapshot.'
    mkdir "$snapshot/unpacked"
    ditto -x -k --norsrc "$upload" "$snapshot/unpacked"
    app="$snapshot/unpacked/Soulseek-Arpeggio.app"
    bash "$root/scripts/verify-artifact.sh" "--$mode" "$app"
    args=(--repo "$PUBLIC_REPOSITORY" --target "$sha" --title "Arpeggio $version")
    if [ "$mode" = preview ]; then args+=(--prerelease); fi
    if [ -n "$notes" ]; then args+=(--notes-file "$notes"); else args+=(--generate-notes); fi
    assert_artifact_source "$app" "$sha" "$version"
    [ "$(archive_digest "$upload")" = "$digest" ] && [ "$(archive_digest "$archive")" = "$digest" ] || fail 'Prepared archive changed before publication.'
    assert_release_source "$root" "$sha" "$version"
    gh release create "v$version" "$upload" "${args[@]}"
)
