#!/bin/bash
#   usage: tools/crowd_dump.sh outdir  -- plays the macro, then dumps frames until one has the crowd draws (ps B4BBEA)
export PATH=$PATH:$HOME/Library/Android/sdk/platform-tools
B=com.pes2017.recomp; F=/sdcard/Android/data/$B/files; OUT=$1; mkdir -p "$OUT"
"$(dirname "$0")"/run_macro.sh "0 32" play | tail -1
for i in 1 2 3 4 5 6 7 8; do
  adb shell "touch $F/dump_frame"; sleep 5
  adb exec-out "cat $F/game.log" > "$OUT/log.txt"
  python3 - "$OUT/log.txt" <<'PY' && break
import sys
t=open(sys.argv[1],errors='replace').read().split('\n')
s=max(i for i,l in enumerate(t) if l.startswith('===== new run'))
b=[i for i,l in enumerate(t[s:]) if 'DUMP frame begins' in l]
if not b: sys.exit(1)
last=t[s:][b[-1]:]
open(sys.argv[1]+'.last','w').write('\n'.join(last))
sys.exit(0 if any('DUMP draw' in l and 'ps B4BBEAC4E75DDB31' in l for l in last) else 1)
PY
done
echo "dump attempt $i"
for n in 06C50000 06EA0000 07EB0000 08370000; do adb pull $F/frame_images/resolve_${n}_a.pgm "$OUT/" >/dev/null 2>&1; adb pull $F/frame_images/resolve_$n.pnm "$OUT/" >/dev/null 2>&1; done
