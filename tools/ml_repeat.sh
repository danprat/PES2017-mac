#!/usr/bin/env bash
# Repeat the Master League setup route and report which runs got past Manager Settings
# (screen matches /tmp/ml_ok_ref.png, the Choose Lineup Type popup) and which hung.
#   tools/ml_repeat.sh [runs=5]
cd "$(dirname "$0")/.."
F=/sdcard/Android/data/com.pes2017.recomp/files
for n in $(seq 1 "${1:-5}"); do
    adb shell touch $F/heap_watch
    tools/to_ml.sh ml >/dev/null 2>&1
    sleep 4
    adb exec-out screencap -p > /tmp/ml_run_$n.png
    verdict=$(python3 - "$n" <<'PY'
import sys
from PIL import Image, ImageChops, ImageStat
a = Image.open('/tmp/ml_ok_ref.png').convert('RGB').crop((300, 200, 1300, 560)).resize((250, 90))
b = Image.open('/tmp/ml_run_%s.png' % sys.argv[1]).convert('RGB').crop((300, 200, 1300, 560)).resize((250, 90))
d = sum(ImageStat.Stat(ImageChops.difference(a, b)).mean) / 3
print('past (diff %.1f)' % d if d < 12 else 'STUCK (diff %.1f)' % d)
PY
)
    broken=$(tools/logtail.sh run "heapcheck: BROKEN" | head -1 | cut -c1-160)
    echo "run $n: $verdict ${broken:+| $broken}"
done
