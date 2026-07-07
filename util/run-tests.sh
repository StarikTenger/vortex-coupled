apps=(basic conv3 cta demo diverge dogfood dotproduct dropout fence io_addr madmax mstress printf relu sgemm sgemm_tcu sgemm2 sgemv sort stencil3d vecadd)

mkdir -p blackbox_logs

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

fmt_time() {
    local total=$1
    printf "%02d:%02d" $((total / 60)) $((total % 60))
}

run_suite() {
    local label="$1"
    shift
    local extra_args=("$@")
    local suite_start=$SECONDS

    echo "$label:"

    for app in "${apps[@]}"; do
        logfile="blackbox_logs/${app}.log"

        local test_start=$SECONDS
        ./ci/blackbox.sh --cores=4 --app="$app" "${extra_args[@]}" >"$logfile" 2>&1
        status=$?
        local test_elapsed=$((SECONDS - test_start))

        if [ $status -eq 0 ]; then
            echo -e "${GREEN}[PASS]${NC} ($(fmt_time $test_elapsed)) $app"
        elif [ $status -gt 128 ]; then
            signal=$((status - 128))
            echo -e "${YELLOW}[CRASH]${NC} ($(fmt_time $test_elapsed)) $app (terminated by signal $signal)"
        else
            echo -e "${RED}[FAIL]${NC} ($(fmt_time $test_elapsed)) $app (exit code $status)"
        fi
    done

    echo "$label total: $(fmt_time $((SECONDS - suite_start)))"
}

overall_start=$SECONDS

run_suite "no debug flag"
run_suite "debug=0" --debug=0

echo "overall total: $(fmt_time $((SECONDS - overall_start)))"
