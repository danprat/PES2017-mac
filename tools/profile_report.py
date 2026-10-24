#!/usr/bin/env python3
"""Turns the runtime's PES17_PROFILE dump (the `profile-*` lines in game.log) into function names.
usage: tools/profile_report.py game.log [libpes17.so] [top=14]

The dump is raw addresses and the process's executable memory map, because the library on the
phone is stripped and a signal handler cannot look names up; the unstripped build
(build-android/libpes17.so) has them. Only the last dump in the log is read.
"""
import collections, glob, os, re, subprocess, sys

log = sys.argv[1]
lib = sys.argv[2] if len(sys.argv) > 2 else os.path.join(os.path.dirname(__file__), '..', 'build-android', 'libpes17.so')
top = int(sys.argv[3]) if len(sys.argv) > 3 else 14
ndks = [d for d in sorted(glob.glob(os.path.expanduser('~/Library/Android/sdk/ndk/*')),
                          key=lambda d: [int(x) for x in os.path.basename(d).split('.') if x.isdigit()])
        if os.path.exists(os.path.join(d, 'toolchains/llvm/prebuilt/darwin-x86_64/bin/llvm-symbolizer'))]
symbolizer = os.path.join(ndks[-1], 'toolchains/llvm/prebuilt/darwin-x86_64/bin/llvm-symbolizer') if ndks else 'llvm-symbolizer'

text = open(log, errors='replace').read().splitlines()
ends = [i for i, l in enumerate(text) if 'profile: dumped' in l]
begin = ends[-2] + 1 if len(ends) >= 2 else 0
end = ends[-1] + 1 if ends else len(text)
maps, totals, rows = [], {}, []
for l in text[begin:end]:
    m = re.search(r'profile-map (\S+)-(\S+) (\S+) (\S+) \S+ \S+\s+(\S.*)$', l)
    if m: maps.append((int(m.group(1), 16), int(m.group(2), 16), int(m.group(4), 16), m.group(5).strip()))
    m = re.search(r'profile: (\S+): (\d+) samples', l)
    if m: totals[m.group(1)] = int(m.group(2))
    m = re.search(r'profile-(leaf|incl) (\S+) (\d+) ([0-9a-f]+)', l)
    if m: rows.append((m.group(1), m.group(2), int(m.group(3)), int(m.group(4), 16)))

bases = {}
for start, stop, off, path in maps:
    if off == 0 and path not in bases: bases[path] = start
def locate(addr):
    for start, stop, off, path in maps:
        if start <= addr < stop:
            return path, addr - bases.get(path, start - off)
    return None, addr

located = {a: locate(a) for a in {r[3] for r in rows}}
mine = sorted({o for p, o in located.values() if p and os.path.basename(p) == 'libpes17.so'})
names = {}
if mine:
    out = subprocess.run([symbolizer, '--obj=' + lib, '-f', '-C', '--no-inlines'] + [hex(o) for o in mine],
                         capture_output=True, text=True).stdout.split('\n\n')
    for o, block in zip(mine, out): names[o] = block.split('\n')[0].strip() or '?'

def label(addr):
    path, off = located[addr]
    if path is None: return f'{addr:x}'
    if os.path.basename(path) == 'libpes17.so': return names.get(off, f'libpes17+{off:x}')
    return f'{os.path.basename(path)}+{off:x}'

for thread in sorted({r[1] for r in rows}):
    n = totals.get(thread, 0) or 1
    print(f'== {thread}: {n} samples')
    for kind, title in (('leaf', 'where it is'), ('incl', 'on the stack')):
        agg = collections.Counter()
        for k, t, c, a in rows:
            if k == kind and t == thread: agg[label(a)] += c
        print(f'  -- {title}')
        for name, c in agg.most_common(top): print(f'     {c / n * 100:5.1f}%  {name[:100]}')
