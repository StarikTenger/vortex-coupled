#!/usr/bin/env bash
# Capture blackbox.sh + simulator output for one or more regression apps into
# test-failure-investigation/logs/, named <app>.debug<level>.{run,blackbox}.log.
#
# blackbox.sh redirects real program output to a shared build/run.log that gets
# overwritten on every run, so we pass --log=<path> to give each capture its own
# file (see test-failure-investigation/report.md, "A note on exit codes").
#
# Must be run from build/ (blackbox.sh resolves paths relative to there).
#
# Usage:
#   ./collect-logs.sh <debug-level> <app> [app...]
#
# Examples:
#   ./collect-logs.sh 0 diverge dogfood dropout io_addr printf sgemm_tcu
#   ./collect-logs.sh 3 dropout printf

set -euo pipefail

if [ $# -lt 2 ]; then
    echo "Usage: $0 <debug-level> <app> [app...]" >&2
    exit 1
fi

debug_level=$1
shift

outdir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/logs"
mkdir -p "$outdir"

for app in "$@"; do
    run_log="$outdir/${app}.debug${debug_level}.run.log"
    blackbox_log="$outdir/${app}.debug${debug_level}.blackbox.log"

    echo "[collect-logs] $app --debug=$debug_level -> ${run_log#"$outdir/"}"
    ./ci/blackbox.sh --cores=4 --driver=simx --app="$app" --debug="$debug_level" --log="$run_log" \
        >"$blackbox_log" 2>&1 || true
done
