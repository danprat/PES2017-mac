#!/usr/bin/env python3
"""Find one-frame flashes and flickers in a screen recording.
usage: tools/flicker.py video.mp4 [outdir]
A frame is flagged when it differs a lot from both neighbours while the
neighbours are alike (something shown for a single frame), or when its
brightness jumps and comes straight back."""
import os, subprocess, sys
from PIL import Image, ImageChops, ImageStat
video = sys.argv[1]; out = sys.argv[2] if len(sys.argv) > 2 else '/tmp/flicker'
os.makedirs(out, exist_ok=True)
for f in os.listdir(out):
    if f.startswith('v'): os.remove(os.path.join(out, f))
# The game area only (the touch controls sit on the sides), small.
subprocess.run(['ffmpeg', '-loglevel', 'error', '-i', video, '-vf', 'crop=iw*0.76:ih*0.84:iw*0.11:ih*0.08,scale=320:-1',
                os.path.join(out, 'v%05d.png')], check=True)
files = sorted(f for f in os.listdir(out) if f.startswith('v'))
imgs = [Image.open(os.path.join(out, f)).convert('RGB') for f in files]
def diff(a, b): return sum(ImageStat.Stat(ImageChops.difference(a, b)).mean) / 3
def lum(a): return sum(ImageStat.Stat(a).mean) / 3
hits = []
for i in range(1, len(imgs) - 1):
    ab, bc, ac = diff(imgs[i-1], imgs[i]), diff(imgs[i], imgs[i+1]), diff(imgs[i-1], imgs[i+1])
    la, lb, lc = lum(imgs[i-1]), lum(imgs[i]), lum(imgs[i+1])
    if (ab > 8 and bc > 8 and ac < 0.4 * min(ab, bc)) or (abs(lb - la) > 20 and abs(lb - lc) > 20 and abs(la - lc) < 8):
        hits.append(i)
        print('frame %d (%.2f s): prev %.1f next %.1f skip %.1f, brightness %.0f -> %.0f -> %.0f' % (i, i / 60, ab, bc, ac, la, lb, lc))
print('%d frames, %d flagged' % (len(imgs), len(hits)))
for i in hits[:6]:
    strip = Image.new('RGB', (imgs[0].width * 3, imgs[0].height))
    for k in range(3): strip.paste(imgs[i - 1 + k], (k * imgs[0].width, 0))
    strip.save(os.path.join(out, 'hit_%05d.png' % i))
