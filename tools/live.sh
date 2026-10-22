#!/bin/sh
# Phone side of tools/live.py: a rolling screen recording, four 15 s segments in /sdcard/live_N.mp4.
i=0
while true; do
    screenrecord --time-limit 15 --bit-rate 10000000 /sdcard/live_$((i % 4)).mp4
    i=$((i + 1))
done
