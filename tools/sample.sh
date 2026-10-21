#!/usr/bin/env bash
# GPU busy/clock and the busiest game threads, every ~2 s, for N samples (root).
#   tools/sample.sh [samples=30]
P=$(adb shell pidof com.pes2017.recomp:game)
T0=$(date +%s)
for i in $(seq 1 "${1:-30}"); do
    out=$(adb shell "su -c 'cat /sys/class/kgsl/kgsl-3d0/gpu_busy_percentage; cat /sys/class/kgsl/kgsl-3d0/devfreq/cur_freq; top -H -b -n 1 -p $P | sed -n 6,9p'")
    python3 - "$(( $(date +%s) - T0 ))" "$out" <<'PY'
import sys
lines = sys.argv[2].splitlines()
busy = lines[0].split()[0]; mhz = int(lines[1]) // 1000000
threads = []
for l in lines[2:]:
    f = l.split()
    if len(f) > 11: threads.append('%s %s%%' % (' '.join(f[11:-1])[:22], f[8]))
print('%3ss gpu %s%% %4d MHz | %s' % (sys.argv[1], busy, mhz, ' | '.join(threads)))
PY
done
