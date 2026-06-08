#!/usr/bin/env bash
# Reproduce every log captured under test-failure-investigation/logs/:
#   - Step 0 triage: --debug=0 run of each of the 6 failing regression tests
#   - Step 1 pilot:  --debug=3 instruction traces for dropout and printf
#     (warning: these are huge - tens to hundreds of MB each, see logs/.gitignore)
#
# Must be run from build/.

set -euo pipefail

scriptdir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$scriptdir/collect-logs.sh" 0 diverge dogfood dropout io_addr printf sgemm_tcu
"$scriptdir/collect-logs.sh" 3 dropout printf
