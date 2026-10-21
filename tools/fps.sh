#!/usr/bin/env bash
# Match frame rate: kick off, wait, print the runtime's fps lines (600-swap windows).
#   tools/fps.sh [seconds-after-kickoff=60]
cd "$(dirname "$0")/.."
adb shell cmd statusbar collapse >/dev/null 2>&1
tools/to_match.sh /tmp/fps 0 >/dev/null 2>&1
end=$(( $(date +%s) + ${1:-60} ))
while [ "$(date +%s)" -lt $end ]; do adb shell true; done
tools/logtail.sh run "perf: [0-9.]+ fps" | tail -4
echo "temp: $(adb shell cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null)"
