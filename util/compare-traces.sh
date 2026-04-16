corr_trace=$1
err_trace=$2
cat $corr_trace | grep TRACE >corr_cleaned.log
cat $err_trace | grep TRACE >err_cleaned.log
vimdiff corr_cleaned.log err_cleaned.log