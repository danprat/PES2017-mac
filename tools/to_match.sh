#!/usr/bin/env bash
# From a fresh launch to an Exhibition Match kick-off (Arsenal v Arsenal), as fast as
# the game allows: every step waits for the procedure the game logs, not a fixed sleep.
# Needs a system data save (launch once first).
#   tools/to_match.sh [prefix=match] [shots=6] [stop=kickoff|prematch|teams]
#     prematch: stop at the pre-match screen (line-ups, 3D player preview), screenshot $prefix-prematch.png
#     teams:    stop at team select (away side), screenshot $prefix-teams.png
#     kickoff:  press KICK-OFF, then a screenshot every 15 s to $prefix-<n>.png
OUT=${1:-match}; SHOTS=${2:-6}; STOP=${3:-kickoff}
PKG=com.pes2017.recomp; LOG=/sdcard/Android/data/$PKG/files/game.log
cd "$(dirname "$0")/.."
T0=$(date +%s)
A()     { adb shell input swipe 1448 560 1448 560 120; sleep "${1:-1.5}"; }
START() { adb shell input swipe 960 56 960 56 120; }
DPAD()  { case $1 in up) adb shell input swipe 160 128 160 128 100;; down) adb shell input swipe 160 275 160 275 100;;
          left) adb shell input swipe 87 202 87 202 100;; right) adb shell input swipe 233 202 233 202 100;; esac; sleep "${2:-0.7}"; }
# The procedures of this run so far (the log's last run marker onward).
procs() { adb exec-out "sed -n '/^===== new run/h; /^===== new run/!H; \${x;p}' $LOG | grep 'procedure:'" 2>/dev/null; }
seen()  { procs | grep -q "$1"; }
# wait_for PATTERN SECONDS [ACTION]: poll every 0.5 s; run ACTION between polls.
wait_for() {
    local end=$(( $(date +%s) + $2 ))
    while [ "$(date +%s)" -lt $end ]; do
        seen "$1" && { echo "  $(( $(date +%s) - T0 ))s: $1"; return 0; }
        [ -n "${3:-}" ] && $3
        sleep 0.5
    done
    echo "  timed out waiting for $1"; return 1
}

# The run marker names the pid; the log is the previous run's until it changes
# (the app trims the file when it opens it, so a count of markers will not do).
marker() { adb exec-out "grep '^===== new run' $LOG | tail -1" 2>/dev/null | tr -d '\r'; }
adb shell am force-stop $PKG
before=$(marker)
adb shell am start -n $PKG/com.pes2017.recomp.MainActivity >/dev/null
for i in $(seq 1 120); do [ "$(marker)" != "$before" ] && break; sleep 0.5; done
wait_for "PreStartup" 60 || exit 1                     # the title screen comes up after this
wait_for "SystemDataLoad" 90 START || exit 1           # press START on the title until the load starts
wait_for "TopMenu/TopMenu" 90 "A 1" || exit 1          # past the language screens and data packs
sleep 2.5                                              # the menu's intro animation eats input
DPAD right; DPAD right; A 2                            # PLAY MATCH
DPAD down; A 1
wait_for "Exhibition/ExhibiFlowInit" 15 "A 1" || exit 1
wait_for "LiveData/LiveDataCheck" 15 "A 1" || exit 1  # controller side
sleep 1.5; A 3                                         # Live Update: No
A 3                                                    # English League, Arsenal at home -> away side
[ "$STOP" = teams ] && { adb exec-out screencap -p > "$OUT-teams.png"; echo "team select ($(( $(date +%s) - T0 ))s)"; exit 0; }
# The pre-match screen is recognised by its selected KICK-OFF tile (a pulsing blue near #1A76F5 at two
# points of the 1600x720 frame); a "Live Update" dialog only comes up some runs, so
# the number of presses to get there varies.
prematch() { adb exec-out screencap 2>/dev/null | python3 -c "
import sys; d = sys.stdin.buffer.read(); w = int.from_bytes(d[0:4], 'little')
blue = lambda x, y: (lambda r, g, b: r < 0x40 and 0x50 <= g <= 0x90 and b > 0xC0)(*d[16 + (y * w + x) * 4:][:3])
sys.exit(0 if blue(720, 570) and blue(880, 570) else 1)"; }
# Each press: poll the screen for up to 6 s (the tiles slide in) before the next one.
at_prematch=0
for i in 1 2 3 4; do
    A 1.5
    for j in 1 2 3 4 5 6; do prematch && { at_prematch=1; break; }; sleep 0.5; done
    [ $at_prematch = 1 ] && break
done                                                   # away league, away team -> pre-match
prematch || { echo "  not at the pre-match screen"; adb exec-out screencap -p > "$OUT-lost.png"; exit 1; }
[ "$STOP" = prematch ] && { adb exec-out screencap -p > "$OUT-prematch.png"; echo "pre-match ($(( $(date +%s) - T0 ))s)"; exit 0; }
A 1                                                    # KICK-OFF
wait_for "Match/MatchSetup" 20 "A 1.5"
echo "kick-off after $(( $(date +%s) - T0 ))s"
for i in $(seq 1 "$SHOTS"); do sleep 15; adb exec-out screencap -p > "$OUT-$i.png"; done
procs | tail -2
