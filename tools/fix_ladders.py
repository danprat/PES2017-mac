#!/usr/bin/env python3
"""Find branches whose target label is not in the function that contains them,
and derive the explicit function extents that make them reachable.

Some code (a `bdzf` ladder dispatching into an unrolled tail, for instance) jumps
to addresses that XenonAnalyse has made the entry points of *other* functions.
XenonRecomp then emits `goto loc_X` with no such label, which the C++ compiler
rejects ("use of undeclared label") only after minutes of building. This reads
the generated C++ instead, so it is a check that runs in seconds.

For each offending function F with outside targets T, the fix is a `functions`
entry covering F up to the first function start after the highest target, so the
targets become interior labels. The entries are merged into config/PES.toml
between marker comments, replacing the previous batch; run build.sh's loop
(recompile -> this tool) until it reports nothing.

usage: fix_ladders.py <ppc-dir> [--apply config/PES.toml]
"""
import bisect, glob, re, sys
import title

ppc = sys.argv[1]
func_re = re.compile(r'^PPC_FUNC_IMPL\(__imp__sub_([0-9A-F]+)\)', re.M)
goto_re = re.compile(r'goto (loc_[0-9A-F]+);')
label_re = re.compile(r'^(loc_[0-9A-F]+):', re.M)

mapping = open(f"{ppc}/ppc_func_mapping.cpp").read()
starts = sorted(set(int(x, 16) for x in re.findall(r'\{ 0x([0-9A-F]{8}), ', mapping)))

bad = {}   # function start -> set of outside targets
for path in glob.glob(f"{ppc}/ppc_recomp.*.cpp"):
    src = open(path).read()
    heads = [(m.start(), int(m.group(1), 16)) for m in func_re.finditer(src)]
    for i, (pos, addr) in enumerate(heads):
        end = heads[i + 1][0] if i + 1 < len(heads) else len(src)
        body = src[pos:end]
        missing = set(goto_re.findall(body)) - set(label_re.findall(body))
        if missing:
            bad.setdefault(addr, set()).update(int(m[4:], 16) for m in missing)

entries = {}
for fn, targets in sorted(bad.items()):
    hi = max(targets | {fn})
    j = bisect.bisect_right(starts, hi)
    end = starts[j] if j < len(starts) else hi + 4
    entries[fn] = end - fn
    print(f"  sub_{fn:08X}: {len(targets)} outside target(s), up to {max(targets):08X} -> size 0x{end - fn:X}")
print(f"{len(entries)} function(s) need an explicit extent", file=sys.stderr)

if "--apply" in sys.argv:
    import tomlblock
    path = sys.argv[sys.argv.index("--apply") + 1]
    n = tomlblock.apply(path, "fix_ladders", entries)
    print(f"applied: {n} entries in {path}", file=sys.stderr)
sys.exit(1 if entries else 0)
