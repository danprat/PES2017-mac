#!/usr/bin/env bash
# Relaunch the game and press START every 3 s until the SystemDataLoad dialog
# (the first screen with text) is up; screenshot to $1 (default dialog.png).
#   TEX6=<hex> sets files/tex6_swz (guest swizzle override for 8_8_8_8 textures) for this run.
OUT=${1:-dialog.png}; EXT=/sdcard/Android/data/com.pes2017.recomp/files; PKG=com.pes2017.recomp
cd "$(dirname "$0")/.."
adb shell am force-stop $PKG
if [ -n "${TEX6:-}" ]; then adb shell "echo $TEX6 > $EXT/tex6_swz"; else adb shell "rm -f $EXT/tex6_swz"; fi
adb shell am start -n $PKG/com.pes2017.recomp.MainActivity >/dev/null
sleep 25
for i in $(seq 1 60); do
    adb shell input swipe 960 56 960 56 200
    sleep 3
    if tools/logtail.sh run procedure | grep -q "SystemDataLoad\|FirstFlow"; then break; fi
done
sleep 12
adb exec-out screencap -p > "$OUT"
tools/logtail.sh run procedure | tail -2
