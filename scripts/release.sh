#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/lib/distribution.sh"
source "$ROOT/scripts/lib/release-orchestration.sh"
[ "$#" -ge 3 ] || fail 'Usage: release.sh prepare|publish preview|production FULL_PUBLIC_MAIN_SHA [notes-file]'
run_release "$1" "$2" "$3" "$ROOT" "${4:-}"
