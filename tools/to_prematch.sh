#!/usr/bin/env bash
# Fresh launch to the Exhibition pre-match screen: London FC (home) v Arsenal (away).
#   tools/to_prematch.sh        then look at /tmp/prematch.png (kits)
cd "$(dirname "$0")/.."
PKG=com.pes2017.recomp; LOG=/sdcard/Android/data/$PKG/files/game.log
tools/pad.sh clear
adb shell am force-stop $PKG
adb shell am start -n $PKG/com.pes2017.recomp.MainActivity >/dev/null
wait_for() { for i in $(seq 1 $2); do tools/logtail.sh run "procedure:" | grep -q "$1" && return 0; [ -n "${3:-}" ] && $3; sleep 1; done; echo "timed out: $1"; return 1; }
START() { tools/pad.sh tap 0 START 0.15; }; A1() { tools/pad.sh tap 0 A 0.15; }
wait_for "SystemDataLoad" 120 START || exit 1
wait_for "TopMenu/TopMenu" 120 A1 || exit 1
sleep 3
tools/pad.sh tap 0 RB; sleep 2; tools/pad.sh tap 0 A; sleep 3
tools/pad.sh tap 0 DOWN; sleep .6; tools/pad.sh tap 0 A; sleep 4
for i in 1 2 3; do tools/pad.sh tap 0 A; sleep 3; done; sleep 3
tools/pad.sh tap 0 A; sleep 3
# HOME_DOWNS: how far down the English League list the home team is (2 = London FC); AWAY_DOWNS likewise.
for i in $(seq 1 ${HOME_DOWNS:-2}); do tools/pad.sh tap 0 DOWN; sleep .4; done; sleep .6
tools/pad.sh tap 0 A; sleep 3
[ -n "${AWAY_DOWNS:-}" ] && { for i in $(seq 1 $AWAY_DOWNS); do tools/pad.sh tap 0 DOWN; sleep .4; done; sleep .6; }
tools/pad.sh tap 0 A; sleep 3; tools/pad.sh tap 0 A; sleep 6
adb exec-out screencap -p > /tmp/prematch_full.png
python3 -c "
from PIL import Image
Image.open('/tmp/prematch_full.png').resize((640, 288)).save('/tmp/prematch.png')"
tools/logtail.sh run "procedure:" | tail -1 | sed -E 's/\(from.*//'
