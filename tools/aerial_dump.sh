#!/bin/bash
# Plays the macro to the match, waits MatchSetup + N s, takes a screenshot and a frame dump, and pulls the logs and images.
#   usage: tools/aerial_dump.sh outdir [extra seconds after MatchSetup=11]
export PATH=$PATH:$HOME/Library/Android/sdk/platform-tools
B=com.pes2017.recomp; F=/sdcard/Android/data/$B/files; OUT=$1; EXTRA=${2:-11}; mkdir -p "$OUT"
procs() { adb exec-out "sed -n '/^===== new run/h; /^===== new run/!H; \${x;p}' $F/game.log | grep 'procedure:'" 2>/dev/null; }
adb shell am force-stop $B
before=$(adb exec-out "grep '^===== new run' $F/game.log | tail -1" | tr -d '\r')
adb shell am start -n $B/.MainActivity >/dev/null
for i in $(seq 1 60); do [ "$(adb exec-out "grep '^===== new run' $F/game.log | tail -1" | tr -d '\r')" != "$before" ] && break; sleep 0.5; done
for i in $(seq 1 120); do procs | grep -q "PreStartup" && break; sleep 0.5; done
sleep 3
adb shell am broadcast -a com.pes2017.recomp.MACRO -p $B --es cmd play --es name play >/dev/null
for i in $(seq 1 300); do procs | grep -q "Match/MatchSetup" && break; sleep 1; done
sleep $EXTRA
adb shell "touch $F/dump_frame"; adb exec-out screencap -p > "$OUT/shot.png"; sleep 5
adb exec-out "cat $F/game.log" > "$OUT/log.txt"
for f in $(adb shell "ls $F/frame_images" | tr -d '\r' | grep -E '^(at_|tex_|resolve_07EB|resolve_08370)'); do adb pull $F/frame_images/$f "$OUT/" >/dev/null 2>&1; done
echo "matchsetup+$EXTRA done"
