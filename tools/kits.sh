#!/usr/bin/env bash
# Every player's kit, from frame dumps: which 256x256 kit texture each player
# draw binds (from guest memory or from a resolve copy) and its average colour,
# classified red / yellow / other. Several dumps a few seconds apart are merged,
# so players off camera in one frame are counted in another.
#   tools/kits.sh [dumps=6] [seconds-between=4]       (run during a match)
cd "$(dirname "$0")/.."
F=/sdcard/Android/data/com.pes2017.recomp/files
DUMPS=${1:-6}; GAP=${2:-4}
: > /tmp/kits_all.txt
for n in $(seq 1 "$DUMPS"); do
    before=$(adb exec-out "grep -c 'DUMP samples end' $F/game.log" | tr -d '\r')
    adb shell touch $F/dump_frame
    for i in $(seq 1 40); do
        now=$(adb exec-out "grep -c 'DUMP samples end' $F/game.log" | tr -d '\r')
        [ "$now" != "$before" ] && break
    done
    tools/logtail.sh run > /tmp/kits_run.txt
    a=$(grep -n "DUMP frame begins" /tmp/kits_run.txt | tail -1 | cut -d: -f1)
    sed -n "$a,\$p" /tmp/kits_run.txt | grep "DUMP   kit slot 0:" | sed -E 's/.*slot 0: //' | sort -u > /tmp/kits_one.txt
    cat /tmp/kits_one.txt >> /tmp/kits_all.txt
    python3 - "$n" <<'PY'
import sys
c = {}
for line in open('/tmp/kits_one.txt'):
    f = line.split()
    if len(f) < 9: continue
    r, g, b = (int(x, 16) for x in f[6:9])
    k = 'red' if (r > g + 30 and r > b + 30 and abs(g - b) < 40) else 'yellow' if (r > b + 50 and g > b + 30) else 'teal' if (g > r + 15 and b > r + 15) else 'official'
    c[k] = c.get(k, 0) + 1
bad = ' <-- WRONG KIT (more than 10 of a team colour, or 3 teal (2 keepers + referee), in one frame)' if c.get('red', 0) > 10 or c.get('yellow', 0) > 10 or c.get('teal', 0) > 3 else ''
print('dump %s: on camera red %d, yellow %d, teal %d, official %d%s' % (sys.argv[1], c.get('red', 0), c.get('yellow', 0), c.get('teal', 0), c.get('official', 0), bad))
PY
    [ "$n" -lt "$DUMPS" ] && sleep "$GAP"
done
# addr layout source "avg bytes" A R G B
python3 - <<'PY'
seen = {}
for line in open('/tmp/kits_all.txt'):
    f = line.split()
    if len(f) < 9: continue
    addr, src = f[0], f[2]
    r, g, b = (int(x, 16) for x in f[6:9])
    if r > g + 30 and r > b + 30 and abs(g - b) < 40: colour = 'red'
    elif r > b + 50 and g > b + 30: colour = 'yellow'
    elif g > r + 15 and b > r + 15: colour = 'teal'
    else: colour = 'official'
    seen[addr] = (src, colour, '%02X %02X %02X' % (r, g, b))
for addr, (src, colour, rgb) in sorted(seen.items(), key=lambda kv: (kv[1][1], kv[0])):
    print('%s %-12s %-6s %s' % (addr, src, colour, rgb))
counts = {}
for v in seen.values(): counts[v[1]] = counts.get(v[1], 0) + 1
print('\nkit textures seen: %d -- red %d, yellow %d, teal %d, official %d' % (len(seen), counts.get('red', 0), counts.get('yellow', 0), counts.get('teal', 0), counts.get('official', 0)))
PY

echo
echo "--- kit compositions resolved during the load (every player, on camera or not):"
tools/logtail.sh run "kitcompose" | python3 -c "
import sys
rows = [l.split() for l in sys.stdin if 'kitcompose' in l]
counts = {}
for f in rows:
    i = f.index('kitcompose'); addr = f[i+1]; r, g, b = (int(x, 16) for x in f[i+3:i+6]); frame = f[i+7]
    if r > g + 30 and r > b + 30 and abs(g - b) < 40: c = 'red'
    elif r > b + 50 and g > b + 30: c = 'yellow'
    elif g > r + 15 and b > r + 15: c = 'teal'
    else: c = 'official'
    counts[c] = counts.get(c, 0) + 1
    print('  %s %-6s %02X %02X %02X frame %s' % (addr, c, r, g, b, frame))
print('compositions: %d -- red %d, yellow %d, teal %d, official %d' % (len(rows), counts.get('red', 0), counts.get('yellow', 0), counts.get('teal', 0), counts.get('official', 0)))
"
