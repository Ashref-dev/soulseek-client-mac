#!/usr/bin/env bash
# Builds and runs the isolated long-session workload against a loopback fixture.
# Uses two generated profiles in a temporary folder: no real account, Keychain item, owner data or UI.
# Usage: scripts/perf-long-session.sh [output.json] [extra ArpeggioPerformance arguments]
set -euo pipefail

cd "$(dirname "$0")/.."
output="${1:-.omo/evidence/perf-long-session.json}"
shift || true
mkdir -p "$(dirname "$output")"

swift build -c release --product ArpeggioPerformance
binary="$(swift build -c release --product ArpeggioPerformance --show-bin-path)/ArpeggioPerformance"

started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
set +e
"$binary" --output "$output" "$@"
status=$?
set -e
echo "long session started ${started}, exit ${status}, report: ${output}" >&2
exit "$status"
