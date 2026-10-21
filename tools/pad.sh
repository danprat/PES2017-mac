#!/usr/bin/env bash
# Virtual controllers on the phone (files/pad, read by runtime/kernel/input.cpp).
#   tools/pad.sh set <user> [buttons...] [lx=N ly=N rx=N ry=N lt=N rt=N]   hold until changed
#   tools/pad.sh tap <user> <button> [seconds=0.15]                         press and release
#   tools/pad.sh clear                                                       no virtual pads
# Buttons: A B X Y LB RB BACK START LS RS UP DOWN LEFT RIGHT. Sticks -32768..32767.
# User 1 shows up as a second controller (the other team).
F=/sdcard/Android/data/com.pes2017.recomp/files/pad
bit() { case $1 in UP) echo 1;; DOWN) echo 2;; LEFT) echo 4;; RIGHT) echo 8;; START) echo 16;; BACK) echo 32;;
                  LS) echo 64;; RS) echo 128;; LB) echo 256;; RB) echo 512;; A) echo 4096;; B) echo 8192;;
                  X) echo 16384;; Y) echo 32768;; *) echo 0;; esac; }
STATE=/tmp/pes_pad_state; touch "$STATE"
line_for() {   # user args... -> "user hex lx ly rx ry lt rt"
    local user=$1; shift; local b=0 lx=0 ly=0 rx=0 ry=0 lt=0 rt=0
    for a in "$@"; do
        case $a in lx=*) lx=${a#*=};; ly=*) ly=${a#*=};; rx=*) rx=${a#*=};; ry=*) ry=${a#*=};;
                   lt=*) lt=${a#*=};; rt=*) rt=${a#*=};; *) b=$(( b | $(bit "$a") ));; esac
    done
    printf "%u %x %d %d %d %d %d %d\n" "$user" "$b" "$lx" "$ly" "$rx" "$ry" "$lt" "$rt"
}
push() { grep -v "^$1 " "$STATE" > "$STATE.new"; echo "$2" >> "$STATE.new"; mv "$STATE.new" "$STATE"
         adb shell "cat > $F" < "$STATE"; }
case $1 in
    set) user=$2; shift 2; push "$user" "$(line_for "$user" "$@")" ;;
    tap) user=$2; push "$user" "$(line_for "$user" "$3")"; sleep "${4:-0.15}"; push "$user" "$(line_for "$user")" ;;
    clear) : > "$STATE"; adb shell rm -f $F ;;
    *) sed -n 2,8p "$0"; exit 1 ;;
esac
