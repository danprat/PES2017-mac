#!/usr/bin/env bash
# Repeat Master League setup until the data-creation screen stalls, then capture evidence.
# A run is fine when the procedure reaches CmnReportEventCheck (the Club Secretary report).
#   tools/ml_stall_hunt.sh [runs=6] [limit-seconds=45]
cd "$(dirname "$0")/.."
F=/sdcard/Android/data/com.pes2017.recomp/files
LOG=$F/game.log
procs() { adb exec-out "sed -n '/^===== new run/h; /^===== new run/!H; \${x;p}' $LOG | grep 'procedure:'" 2>/dev/null; }
for n in $(seq 1 "${1:-6}"); do
    adb shell touch $F/heap_watch $F/alloc_watch
    tools/to_ml.sh ml >/dev/null 2>&1
    T=$(date +%s); ok=0
    while [ $(( $(date +%s) - T )) -lt "${2:-45}" ]; do
        procs | grep -q "CmnReportEventCheck" && { ok=1; break; }
        sleep 1
    done
    took=$(( $(date +%s) - T ))
    if [ $ok = 1 ]; then echo "run $n: data creation finished in ${took}s"; continue; fi
    echo "run $n: STALL after ${took}s at $(procs | tail -1 | sed -E 's/.*procedure: ([^ ]+).*/\1/') -- capturing"
    adb exec-out screencap -p > /tmp/stall.png
    adb shell "su -c 'rm -f /data/local/tmp/perf.data'"
    P=$(adb shell pidof com.pes2017.recomp:game | tr -d '\r')
    printf 'cd /data/local/tmp && simpleperf record -p %s -f 1000 --call-graph fp --duration 8 -o /data/local/tmp/perf.data\n' "$P" > /tmp/rec.sh
    adb push /tmp/rec.sh /data/local/tmp/rec.sh >/dev/null
    adb shell "su -c 'sh /data/local/tmp/rec.sh'" >/dev/null 2>&1
    adb shell touch $F/check_heap; sleep 1
    adb exec-out "cat $LOG" > /tmp/stall_log.txt
    echo "captured: /tmp/stall.png, /tmp/stall_log.txt, perf.data on the phone"
    exit 0
done
echo "no stall in ${1:-6} runs"
