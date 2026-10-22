#!/usr/bin/env bash
# What the in-game CAPTURE button recorded (or press it from here): the last 240 frames as
# swap:draws:ms, summarised, plus the frame dump of the next frame in game.log.
#   tools/capture.sh [press]     "press" taps the request file instead of the button
cd "$(dirname "$0")/.."
[ "${1:-}" = press ] && { adb shell "echo 1 > /sdcard/Android/data/com.pes2017.recomp/files/capture_request"; sleep 6; }
tools/logtail.sh run "capture:" | python3 -c "
import sys,re,collections
frames=[]
for l in sys.stdin:
    for m in re.finditer(r'(\d+):(\d+):(\d+)', l.split('capture:',1)[1] if 'capture:' in l else ''):
        frames.append(tuple(map(int,m.groups())))
if not frames: print('no capture in this run'); sys.exit()
frames=frames[-240:]
ms=collections.Counter(f[2] for f in frames)
print(len(frames),'frames; frame times (ms):',dict(sorted(ms.items())))
jumps=[(frames[i][0],frames[i-1][1],frames[i][1]) for i in range(1,len(frames)) if abs(frames[i][1]-frames[i-1][1])>20]
print('draw-count jumps >20 (swap, before, after):',jumps[:20])
print('slow frames (>=45 ms):',[(f[0],f[2]) for f in frames if f[2]>=45][:20])
"
