#!/usr/bin/env bash
# Press a button repeatedly and record what happens: thumbnail, procedure, busiest thread.
#   tools/explore.sh [presses=20] [wait=2.5] [button=A]     (thumbnails in /tmp/explore/)
cd "$(dirname "$0")/.."
rm -rf /tmp/explore; mkdir -p /tmp/explore
P=$(adb shell pidof com.pes2017.recomp:game | tr -d '\r')
for n in $(seq 1 "${1:-20}"); do
    tools/pad.sh tap 0 "${3:-A}" 0.1
    sleep "${2:-2.5}"
    adb exec-out screencap -p > /tmp/explore/f$(printf %02d $n).png
    proc=$(tools/logtail.sh run "procedure:" | tail -1 | sed -E 's/.*procedure: ([^ ]+).*/\1/')
    top=$(adb shell "su -c 'top -H -b -n 1 -p $P | sed -n 7p'" | awk '{print $9"% "$(NF-2)" "$(NF-1)}')
    echo "$n: $proc | top thread: $top"
done
python3 - <<'PY'
from PIL import Image
import glob
fs = sorted(glob.glob('/tmp/explore/f*.png'))
th = [Image.open(f).convert('RGB').resize((320, 144)) for f in fs]
cols = 5; rows = (len(th) + cols - 1) // cols
sh = Image.new('RGB', (cols * 320, rows * 144))
for i, t in enumerate(th): sh.paste(t, ((i % cols) * 320, (i // cols) * 144))
sh.save('/tmp/explore/sheet.png')
PY
