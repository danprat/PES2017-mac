#!/usr/bin/env bash
# Fresh launch to the main menu, then into Master League (New). Steps use the virtual pad
# (tools/pad.sh), so touch coordinates do not matter.
#   tools/to_ml.sh [stage]   stage: menu | ml (default ml)
PKG=com.pes2017.recomp; LOG=/sdcard/Android/data/$PKG/files/game.log
cd "$(dirname "$0")/.."
T0=$(date +%s)
tap() { tools/pad.sh tap 0 "$1" 0.15; sleep "${2:-1}"; }
procs() { adb exec-out "sed -n '/^===== new run/h; /^===== new run/!H; \${x;p}' $LOG | grep 'procedure:'" 2>/dev/null; }
wait_for() { local end=$(( $(date +%s) + $2 )); while [ "$(date +%s)" -lt $end ]; do
    procs | grep -q "$1" && { echo "  $(( $(date +%s) - T0 ))s: $1"; return 0; }; [ -n "${3:-}" ] && $3; sleep 0.5; done
    echo "  timed out waiting for $1"; return 1; }
marker() { adb exec-out "grep '^===== new run' $LOG | tail -1" 2>/dev/null | tr -d '\r'; }
tools/pad.sh clear
adb shell am force-stop $PKG; before=$(marker)
adb shell am start -n $PKG/com.pes2017.recomp.MainActivity >/dev/null
for i in $(seq 1 120); do [ "$(marker)" != "$before" ] && break; sleep 0.5; done
wait_for "PreStartup" 60 || exit 1
START() { tools/pad.sh tap 0 START 0.15; }
wait_for "SystemDataLoad" 90 START || exit 1
A1() { tools/pad.sh tap 0 A 0.15; }
wait_for "TopMenu/TopMenu" 90 A1 || exit 1
sleep 3
[ "${1:-ml}" = menu ] && exit 0
for i in 1 2 3; do tap RB 1.2; done      # HOME -> MATCH -> COMPETITION -> FOOTBALL LIFE
tap RIGHT 1                      # MASTER LEAGUE
tap A 3                          # New / Load popup
[ "${1:-ml}" = popup ] && exit 0
tap A 12                         # New: the intro cutscene plays
tap A 4                          # skip it -> General Settings
tap A 4                          # OK -> nationality notice
tap A 2; tap A 2; tap A 3        # dismiss; Europe; Albania -> "enter the manager's details"
tap A 3                          # dismiss -> Manager Settings
tap A 2.5                        # Manager's Name: the Android text dialog
adb shell input text Tester; sleep 1
adb shell input tap 1142 502; sleep 2.5      # the dialog's OK
echo "name entered ($(( $(date +%s) - T0 ))s)"
[ "${1:-ml}" = name ] && exit 0
tap DOWN 0.8; tap DOWN 0.8; tap A 6          # OK -> Choose Lineup Type
echo "past manager settings ($(( $(date +%s) - T0 ))s)"
[ "${1:-ml}" = lineup ] && exit 0
# Lineup popup, Club Team Lineup, the "choose the club" notice, Arsenal, Coop Match
# Settings OK, then the Game Tips loading screen while the league data is created.
for i in 1 2 3 4 5 6 7; do tap A 1; done
echo "on the data-creation screen ($(( $(date +%s) - T0 ))s)"
