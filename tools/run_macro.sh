#!/bin/bash
# Plays a recorded controller macro from game start to a match, then reads fps / CPU cycles / skin temperature.
#   usage: tools/run_macro.sh "<sleep us> <free yields>" [macro=play]
export PATH=$PATH:$HOME/Library/Android/sdk/platform-tools
B=com.pes2017.recomp; F=/sdcard/Android/data/$B/files; M=${2:-play}
procs() { adb exec-out "sed -n '/^===== new run/h; /^===== new run/!H; \${x;p}' $F/game.log | grep 'procedure:'" 2>/dev/null; }
adb shell "echo $1 > $F/yield_tuning"
adb shell am force-stop $B
before=$(adb exec-out "grep '^===== new run' $F/game.log | tail -1" | tr -d '\r')
adb shell am start -n $B/.MainActivity >/dev/null
for i in $(seq 1 60); do [ "$(adb exec-out "grep '^===== new run' $F/game.log | tail -1" | tr -d '\r')" != "$before" ] && break; sleep 0.5; done
for i in $(seq 1 120); do procs | grep -q "PreStartup" && break; sleep 0.5; done
sleep 3
adb shell am broadcast -a com.pes2017.recomp.MACRO -p $B --es cmd play --es name $M >/dev/null
T0=$(date +%s)
for i in $(seq 1 240); do procs | grep -q "Match/MatchSetup" && break; sleep 1; done
echo "cfg=[$1] matchsetup after $(( $(date +%s) - T0 ))s of macro; last procs: $(procs | tail -1 | cut -c1-60)"
sleep 30
PID=$(adb shell pidof $B:game)
adb shell su -c "simpleperf record -p $PID --duration 10 -f 500 -o /data/local/tmp/ab.data" >/dev/null 2>&1
CYC=$(adb shell su -c "simpleperf report -i /data/local/tmp/ab.data --sort comm" 2>&1 | grep "Event count" | awk '{print $3}')
FPS=$(adb exec-out "tail -n 4000 $F/game.log" | grep "tele:" | tail -14 | awk '{s+=$4;n++}END{printf "%.1f",s/n}')
SKIN=$(adb shell dumpsys thermalservice | grep "mName=SKIN" | head -1 | sed 's/.*mValue=\([0-9.]*\).*/\1/')
echo "cfg=[$1] fps=$FPS cycles=$CYC skin=$SKIN"
