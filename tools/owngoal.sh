#!/usr/bin/env bash
# Own goal from kick-off (the cutscene + replay test): A to kick off, run left
# to our own goal post, then LT + A toward it.
#   arg 1 = seconds of running. Then a burst of
# screenshots (to /tmp/og/) and the fps lines.
#   tools/owngoal.sh [run-seconds=5] [burst=30]
cd "$(dirname "$0")/.."
RUN=${1:-5}; BURST=${2:-30}
wait_s() { local end=$(( $(date +%s) + $1 )); while [ "$(date +%s)" -lt $end ]; do adb shell true; done; }
adb shell cmd statusbar collapse >/dev/null 2>&1
for try in 1 2; do
    tools/to_match.sh /tmp/og_k 0 2>&1 | grep -q "kick-off after" && break
    [ "$try" = 2 ] && { echo "no kick-off"; exit 1; }
done
wait_s 20                                   # the intro has played; kick-off is waiting
tools/pad.sh tap 0 A 0.2
wait_s 1
tools/pad.sh set 0 lx=-32000                # run left, to our goal
wait_s "$RUN"
adb exec-out screencap -p > /tmp/og_near.png
# Screen video of the goal and its cutscene, for tools/flicker.py.
adb shell rm -f /sdcard/og.mp4
adb shell "screenrecord --time-limit ${RECORD:-28} --bit-rate 12000000 /sdcard/og.mp4" &
REC=$!
# At our goal: LT + A toward it (the user's recipe; untested as of 2026-10-21).
tools/pad.sh set 0 LT A lx=-32000 lt=255
sleep 0.4
tools/pad.sh set 0 lx=-32000
sleep 0.5
tools/pad.sh clear
wait $REC
adb pull /sdcard/og.mp4 /tmp/og.mp4 >/dev/null && echo "video: /tmp/og.mp4"
BURST=0
rm -rf /tmp/og; mkdir -p /tmp/og
for n in $(seq -w 1 "$BURST"); do adb exec-out screencap -p > /tmp/og/f$n.png; done
tools/logtail.sh run "perf: [0-9.]+ fps" | tail -4 | sed -E 's/; vertex.*//'
