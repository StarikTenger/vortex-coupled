apps=(diverge dogfood dropout io_addr relu)

mkdir -p blackbox_logs

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

for app in "${apps[@]}"; do
    logfile="blackbox_logs/${app}.log"

    ./ci/blackbox.sh --cores=4 --app="$app" --debug=0 >"$logfile" 2>&1
    status=$?

    if [ $status -eq 0 ]; then
        echo -e "${GREEN}[PASS]${NC}  $app"
    elif [ $status -gt 128 ]; then
        signal=$((status - 128))
        echo -e "${YELLOW}[CRASH]${NC} $app (terminated by signal $signal)"
    else
        echo -e "${RED}[FAIL]${NC}  $app (exit code $status)"
    fi
done