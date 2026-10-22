#!/usr/bin/env bash
# Fresh launch, Master League -> Load -> first save -> Forward Time "To Next Match" -> the pre-match screen.
cd "$(dirname "$0")/.."
PKG=com.pes2017.recomp
tools/pad.sh clear
adb shell am force-stop $PKG
adb shell am start -n $PKG/com.pes2017.recomp.MainActivity >/dev/null
wait_for() { for i in $(seq 1 $2); do tools/logtail.sh run "procedure:" | grep -q "$1" && return 0; [ -n "${3:-}" ] && $3; sleep 1; done; echo "timed out: $1"; return 1; }
START() { tools/pad.sh tap 0 START 0.15; }; A1() { tools/pad.sh tap 0 A 0.15; }
wait_for "SystemDataLoad" 120 START || exit 1
wait_for "TopMenu/TopMenu" 120 A1 || exit 1
sleep 3
for i in 1 2 3; do tools/pad.sh tap 0 RB; sleep 1.2; done
tools/pad.sh tap 0 RIGHT; sleep 1; tools/pad.sh tap 0 A; sleep 3
tools/pad.sh tap 0 DOWN; sleep .6; tools/pad.sh tap 0 A; sleep 3
wait_for "CmnLoadIdle" 60 || exit 1
sleep 3; tools/pad.sh tap 0 A; sleep 3; tools/pad.sh tap 0 A
wait_for "MainMenuSelector" 90 || exit 1
sleep 5; tools/pad.sh tap 0 A; sleep 1.5; tools/pad.sh tap 0 A
wait_for "CmnCoopSettingsCheck" 90 || exit 1
sleep 8
adb exec-out screencap -p > /tmp/mlm_full.png
python3 -c "
from PIL import Image
Image.open('/tmp/mlm_full.png').resize((800, 360)).save('/tmp/mlm.png')"
tools/logtail.sh run "procedure:" | tail -1 | sed -E 's/\(from.*//'
