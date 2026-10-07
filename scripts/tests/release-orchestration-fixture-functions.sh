plist_value() {
    case "$2" in
    ArpeggioReleaseVersion) printf '%s\n' "$VERSION" ;;
    ArpeggioSourceRevision) printf '%s\n' "${STUB_SIGNED_SHA:-$SHA}" ;;
    ArpeggioSourceTreeState) printf '%s\n' "${STUB_SIGNED_TREE:-clean}" ;;
    *) return 2 ;;
    esac
}
if [ "${STUB_LEGACY_FINAL_GATE:-}" = 1 ]; then
    assert_release_source() {
        SOURCE_CHECK_COUNT=$((${SOURCE_CHECK_COUNT:-0}+1))
        if [ "$SOURCE_CHECK_COUNT" -gt 1 ]; then return 0; fi
        [ "$(GIT_MASTER=1 git -C "$1" rev-parse HEAD)" = "$2" ] || fail 'Initial fixture HEAD mismatch.'
        [ -z "$(GIT_MASTER=1 git -C "$1" status --porcelain)" ] || fail 'Initial fixture source dirty.'
    }
fi
