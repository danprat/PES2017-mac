#!/usr/bin/env python3
"""Disassemble Xenos shader microcode: control flow (from xenos_shader.py), ALU
vector/scalar instructions and texture/vertex fetches, with the field layout of
Xenia's ucode.h (runtime/gpu/xe/shim/rex/graphics/format/ucode.h).

Input: a file of hex dwords (what a frame dump's `DUMP ucode` line holds), or `-`
for stdin.
usage: xenos_disasm.py <dwords.txt> [ps|vs]"""
import importlib.util, os, sys

here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("xs", os.path.join(here, "xenos_shader.py"))
xs = importlib.util.module_from_spec(spec)
_argv, sys.argv = sys.argv, ["xenos_shader.py"]
try:
    spec.loader.exec_module(xs)
except SystemExit:
    pass
sys.argv = _argv

VECTOR = ["add", "mul", "max", "min", "seq", "sgt", "sge", "sne", "frc", "trunc", "floor", "mad",
          "cndeq", "cndge", "cndgt", "dp4", "dp3", "dp2add", "cube", "max4", "setp_eq_push",
          "setp_ne_push", "setp_gt_push", "setp_ge_push", "kill_eq", "kill_gt", "kill_ge",
          "kill_ne", "dst", "maxa"]
SCALAR = {0: "adds", 1: "adds_prev", 2: "muls", 3: "muls_prev", 4: "muls_prev2", 5: "maxs", 6: "mins",
          7: "seqs", 8: "sgts", 9: "sges", 10: "snes", 11: "frcs", 12: "truncs", 13: "floors",
          14: "exp", 15: "logc", 16: "log", 17: "rcpc", 18: "rcpf", 19: "rcp", 20: "rsqc",
          21: "rsqf", 22: "rsq", 23: "maxas", 24: "maxasf", 25: "subs", 26: "subs_prev",
          27: "setp_eq", 28: "setp_ne", 29: "setp_gt", 30: "setp_ge", 31: "setp_inv",
          32: "setp_pop", 33: "setp_clr", 34: "setp_rstr", 35: "kills_eq", 36: "kills_gt",
          37: "kills_ge", 38: "kills_ne", 39: "kills_one", 40: "sqrt", 42: "mulsc0", 43: "mulsc1",
          44: "addsc0", 45: "addsc1", 46: "subsc0", 47: "subsc1", 48: "sin", 49: "cos", 50: "retain_prev"}
# Operand counts (vector): mad/cnd*/dp2add take three.
THREE = {"mad", "cndeq", "cndge", "cndgt", "dp2add"}
ONE = {"frc", "trunc", "floor"}


def bits(v, lo, n):
    return (v >> lo) & ((1 << n) - 1)


def swizzle(sw):
    # Each component's field is relative to its own index.
    s = "".join("xyzw"[(i + ((sw >> (2 * i)) & 3)) & 3] for i in range(4))
    return "" if s == "xyzw" else "." + s


def operand(reg, sel, negate, sw, absolute):
    if sel:   # a temporary
        name = f"r{reg & 0x3F}"
        if reg & 0x80: name = f"|{name}|"
    else:
        name = f"c{reg}"
        if absolute: name = f"|{name}|"
    return ("-" if negate else "") + name + swizzle(sw)


def dest(reg, export, mask, pixel, rel=False):
    m = "".join(c for i, c in enumerate("xyzw") if mask & (1 << i))
    if export:
        if pixel:
            name = {0: "oC0", 1: "oC1", 2: "oC2", 3: "oC3", 61: "oDepth"}.get(reg, f"export{reg}")
        else:
            name = {62: "oPos", 63: "oPts"}.get(reg, f"o{reg}")
    else:
        name = f"r{reg}" + ("[aL]" if rel else "")
    return f"{name}.{m}" if m else None


def alu(d0, d1, d2, pixel):
    vdst, vrel, absc = bits(d0, 0, 6), bits(d0, 6, 1), bits(d0, 7, 1)
    sdst, srel, export = bits(d0, 8, 6), bits(d0, 14, 1), bits(d0, 15, 1)
    vmask, smask = bits(d0, 16, 4), bits(d0, 20, 4)
    vclamp, sclamp, sopc = bits(d0, 24, 1), bits(d0, 25, 1), bits(d0, 26, 6)
    s3sw, s2sw, s1sw = bits(d1, 0, 8), bits(d1, 8, 8), bits(d1, 16, 8)
    s3n, s2n, s1n = bits(d1, 24, 1), bits(d1, 25, 1), bits(d1, 26, 1)
    predc, pred = bits(d1, 27, 1), bits(d1, 28, 1)
    s3r, s2r, s1r = bits(d2, 0, 8), bits(d2, 8, 8), bits(d2, 16, 8)
    vopc, s3sel, s2sel, s1sel = bits(d2, 24, 5), bits(d2, 29, 1), bits(d2, 30, 1), bits(d2, 31, 1)
    out = []
    p = (f"({'' if predc else '!'}p) " if pred else "")
    vname = VECTOR[vopc] if vopc < len(VECTOR) else f"v{vopc}"
    a = operand(s1r, s1sel, s1n, s1sw, absc)
    b = operand(s2r, s2sel, s2n, s2sw, absc)
    c = operand(s3r, s3sel, s3n, s3sw, absc)
    d = dest(vdst, export, vmask, pixel, vrel)
    if d or vname.startswith(("kill", "setp", "maxa")):
        args = [a] if vname in ONE else [a, b, c] if vname in THREE else [a, b]
        out.append(f"{p}{vname}{'_sat' if vclamp else ''} {d or '_'}, {', '.join(args)}")
    sname = SCALAR.get(sopc, f"s{sopc}")
    sd = dest(sdst, export, smask, pixel, srel)
    if (sd or sname.startswith(("kill", "setp"))) and sname != "retain_prev":
        if sname in ("mulsc0", "mulsc1", "addsc0", "addsc1", "subsc0", "subsc1"):
            src = f"{operand(s3r, 0, s3n, s3sw, absc)}, r{s3r & 0x3F}"
        else:
            src = operand(s3r, s3sel, s3n, s3sw, absc)
        out.append(f"{p}{sname}{'_sat' if sclamp else ''} {sd or '_'}, {src}")
    return out


def fetch(d0, d1, d2):
    opc = bits(d0, 0, 5)
    src, dst = bits(d0, 5, 6), bits(d0, 12, 6)
    const = bits(d0, 20, 5)
    if opc == 0:   # vertex fetch
        stride = bits(d2, 0, 8)
        offset = bits(d2, 8, 23)
        fmt = bits(d1, 16, 6)
        dsw = bits(d1, 0, 12)
        comps = "".join("xyzw01__"[bits(dsw, 3 * i, 3)] for i in range(4))
        return f"vfetch r{dst}.{comps}, r{src}, vf{const * 3 + bits(d0, 25, 2)} (fmt {fmt}, stride {stride}, offset {offset})"
    srcsw = bits(d0, 26, 6)
    dsw = bits(d1, 0, 12)
    comps = "".join("xyzw01__"[bits(dsw, 3 * i, 3)] for i in range(4))
    coord = "".join("xyzw"[(i + bits(srcsw, 2 * i, 2)) & 3] for i in range(3))
    names = {1: "tfetch", 16: "getTextureBorderColorFrac", 17: "getTextureComputedLod",
             18: "getTextureGradients", 19: "getTextureWeights", 24: "setTextureLod",
             25: "setTextureGradientsHorz", 26: "setTextureGradientsVert"}
    lod_bias = bits(d2, 1, 7)
    if lod_bias & 0x40: lod_bias -= 0x80
    pred = " (pred)" if bits(d1, 31, 1) else ""
    return f"{names.get(opc, f'fetch{opc}')} r{dst}.{comps}, r{src}.{coord}, tf{const}{pred}" + (f" lod_bias {lod_bias / 16:g}" if lod_bias else "")


def main():
    path = sys.argv[1]
    kind = sys.argv[2] if len(sys.argv) > 2 else "ps"
    text = sys.stdin.read() if path == "-" else open(path).read()
    if "dwords):" in text: text = text.split("dwords):", 1)[1]
    words = [int(w, 16) for w in text.split() if all(c in "0123456789abcdefABCDEF" for c in w)]
    flow, terminated = xs.decode_control_flow(words)
    pixel = kind == "ps"
    for cf in flow:
        print(f"; {cf}")
        if not hasattr(cf, "address") or not hasattr(cf, "count"):
            continue
        for n in range(cf.count):
            i = cf.address + n
            d0, d1, d2 = words[3 * i:3 * i + 3]
            if cf.is_fetch(n):
                print(f"  {i:3}: {fetch(d0, d1, d2)}")
            else:
                for line in alu(d0, d1, d2, pixel):
                    print(f"  {i:3}: {line}")


if __name__ == "__main__":
    main()
