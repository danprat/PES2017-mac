#!/usr/bin/env bash
# From a fresh launch to Exhibition Match's team selection (English League open on
# the HOME side), screenshot to $1. Needs a system data save (launch once first).
OUT=${1:-exhibition.png}
cd "$(dirname "$0")/.."
A() { adb shell input swipe 1448 560 1448 560 200; sleep "${1:-3}"; }
DPAD() { case $1 in up) adb shell input swipe 160 128 160 128 150;; down) adb shell input swipe 160 275 160 275 150;;
         left) adb shell input swipe 87 202 87 202 150;; right) adb shell input swipe 233 202 233 202 150;; esac; sleep 1.5; }
tools/to_dialog.sh /dev/null >/dev/null
for i in 1 2 3 4 5 6; do A 8; tools/logtail.sh run procedure | grep -q TopMenu && break; done
sleep 4
DPAD right; DPAD right; A 4          # PLAY MATCH
DPAD down; A 10                      # Exhibition Match
A 8                                  # controller side
A 10                                 # Live Update: No
A 6                                  # English League
adb exec-out screencap -p > "$OUT"
tools/logtail.sh run procedure | tail -2
