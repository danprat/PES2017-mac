#!/usr/bin/env python3
"""Which draws come and go between consecutive dumped frames (the CAPTURE button dumps 6).
usage: tools/diffdraws.py [game.log copy]   (default: pulls the phone's log)
A draw is keyed by (vertex shader, pixel shader); counts per key are compared. A flicker shows as draws present in
some frames and absent in the next; the tally is per frame."""
import collections, re, subprocess, sys
if len(sys.argv) > 1: text = open(sys.argv[1], errors='replace').read()
else: text = subprocess.run('adb exec-out cat /sdcard/Android/data/com.pes2017.recomp/files/game.log', shell=True, capture_output=True, text=True, errors='replace').stdout
lines = text.split('\n')
start = max(i for i, l in enumerate(lines) if l.startswith('===== new run'))
frames, cur = [], None
for l in lines[start:]:
    if 'DUMP frame begins' in l: cur = collections.Counter(); skips = 0
    elif 'DUMP frame ends' in l and cur is not None: frames.append(cur); cur = None
    elif cur is not None:
        m = re.search(r'DUMP draw \d+: prim (\d+) idx (\d+).* vs (\w+) ps (\w+)', l)
        if m: cur[(m.group(3)[:8], m.group(4)[:8])] += 1
print(len(frames), 'dumped frames;', [sum(f.values()) for f in frames], 'draws each')
for i in range(1, len(frames)):
    gone = frames[i-1] - frames[i]; new = frames[i] - frames[i-1]
    print('frame %d -> %d: %d draws gone, %d new' % (i-1, i, sum(gone.values()), sum(new.values())))
    for k, v in sorted(gone.items(), key=lambda kv: -kv[1])[:6]: print('   gone vs %s ps %s x%d' % (*k, v))
    for k, v in sorted(new.items(), key=lambda kv: -kv[1])[:6]: print('   new  vs %s ps %s x%d' % (*k, v))
