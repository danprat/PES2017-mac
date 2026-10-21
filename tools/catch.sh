#!/usr/bin/env bash
# Relaunch the game, wait until game.log (this run) matches PATTERN, then dump
# every thread's native stack with debuggerd (needs root: Magisk/su) and exit.
# The process is stopped (SIGSTOP) for the dump and resumed after.
#   usage: tools/catch.sh PATTERN [out-file=logs-stacks.txt] [timeout-seconds=300]
set -uo pipefail
PATTERN=${1:?usage: tools/catch.sh PATTERN [out] [timeout]}; OUT=${2:-logs-stacks.txt}; LIMIT=${3:-300}
LOG=/sdcard/Android/data/com.pes2017.recomp/files/game.log
PKG=com.pes2017.recomp
adb shell am force-stop $PKG
adb shell am start -n $PKG/com.mw2.recomp.MainActivity >/dev/null
sleep 2
START=$SECONDS
# Count only lines after this run's marker: grep the tail of the file each poll.
while :; do
    if adb shell "awk '/^===== new run/{n=NR} {l[NR]=\$0} END{for(i=n;i<=NR;i++) print l[i]}' $LOG" | grep -qE "$PATTERN"; then break; fi
    if [ $((SECONDS - START)) -ge "$LIMIT" ]; then echo "timeout: '$PATTERN' not seen in ${LIMIT}s"; exit 1; fi
    sleep 0.5
done
PID=$(adb shell pidof $PKG:game)
# Frozen first: what is caught is often a thread on its way out, and the dump
# takes longer than the title takes to finish.
adb shell su -c "kill -STOP $PID"
adb shell su -c "debuggerd -b $PID > /data/local/tmp/stacks.txt 2>&1"
adb shell su -c "cat /data/local/tmp/stacks.txt" > "$OUT"
adb shell su -c "kill -CONT $PID"
echo "matched '$PATTERN' after $((SECONDS - START))s; $(grep -c '^"' "$OUT") threads dumped to $OUT"
