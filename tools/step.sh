#!/usr/bin/env bash
# One virtual-pad press, then a screenshot (small) to /tmp/step.png.
#   tools/step.sh BUTTON [wait=1.5] [hold=0.1]   e.g. tools/step.sh A 2
cd "$(dirname "$0")/.."
tools/pad.sh tap 0 "$1" "${3:-0.1}"
sleep "${2:-1.5}"
adb exec-out screencap -p > /tmp/step_full.png
python3 -c "
from PIL import Image
Image.open('/tmp/step_full.png').resize((640, 288)).save('/tmp/step.png')"
tools/logtail.sh run "procedure:" | tail -1 | sed -E 's/\(from.*//'
