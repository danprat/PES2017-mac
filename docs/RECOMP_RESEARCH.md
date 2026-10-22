# Xbox 360 recompilation: what we learned and what the pipeline now does

Researched 2026-10-20 for the PES 2017 port. Sources are the XenonRecomp README,
ReXGlue's public docs, and three sibling projects in this workspace
(`mw2-android`, `pinyon-shift`, `Skate3-Port`) read as local checkouts. Numbers
marked **measured here** were produced on PES's own `default.xex`.

## 1. What the other projects do

| Project | Recompiler | What is worth taking |
|---|---|---|
| `mw2-android` | XenonRecomp + a small patch | The architecture we started from. Hand-written fixes for `bdzf` ladders and leaf functions with jump tables (`functions = [...]`). |
| `pinyon-shift` (Forza Horizon) | ShiftGlue, a ReXGlue fork | The most thorough measurements: `docs/RECOMP_OPTIMIZATION_SURVEY.md`, `site/pages/recompiler.md`. Register locals, byte-swap/stack-access work, FP-mode toggle elision, lockstep verification, ARMv8.2 baseline, `-Bsymbolic-functions`. |
| `Skate3-Port` | ReXGlue 0.8 (vendored) | Hand-maintained function bounds (1,776 + 1,741 lines of `end`/`parent` entries). 16 KB-alignment and zipalign checks after the link. ARMv8.2 requirement. Build runs on an Apple-silicon Mac, same as ours. |
| UnleashedRecomp | XenonRecomp | All register-local options on. Reports about 20 MB smaller and "several ms" faster frames, no method given. |

Two things stand out. First, nobody publishes CPU-side numbers except
Pinyon Shift, so most advice is folklore until measured. Second, Skate3-Port's
two function-bounds files show the manual path does not scale; ours is now
derived from the recompiler's own output.

## 2. Measured here: register locals on PES

XenonRecomp's config can keep guest registers in C++ locals instead of the
context struct. One translation unit (`ppc_recomp.78.cpp`, 3.4 MB of generated
C++), NDK clang 19, arm64, `-O2`, **measured here**:

| Config | `.text` | vs base |
|---|---:|---:|
| none (`safe`) | 844 KB | — |
| `ctr` + `xer` | 833 KB | −1.4 % |
| `ctr` + `xer` + `reserved` + `cr` (**`balanced`**) | 694 KB | −17.8 % |
| all eight options (`aggressive`) | 580 KB | −31.3 % |

Why `balanced` is the default and `aggressive` is not:

- The four registers in `balanced` are dead at every call and return under the
  PowerPC ABI, so a function-local copy cannot be observed by a caller. The
  runtime never reads `ctx.cr*`, `ctr`, `xer` or `reserved` (grepped).
- `skip_lr` and the non-volatile/argument locals assume the game obeys the ABI
  everywhere and has no exceptions, and they make any runtime hook that reads
  registers through `ctx` see stale values. Pinyon Shift measured the
  non-volatile variant as *slower* on its codegen (+66 % code, 20-27 % more
  guest time) even though it ran correctly. Our stock-XenonRecomp variant is
  smaller, not larger, but nothing has been run yet, so it stays opt-in until a
  device run validates it.
- Code size is only a proxy. The honest metric is guest instructions per frame
  on a device, which needs the game to boot first.

Select with `PROFILE=safe|balanced|aggressive ./build.sh`.

## 3. Measured here: function discovery is not the bottleneck

- `.pdata` lists 73,078 functions; XenonRecomp ends up with 361,878 entry
  points because it also splits at branch targets that look like calls.
- Only 297 distinct words in `.rdata`/`.data` point into `.text` at an address
  the recompiler did not make a function. Most are integer constants that fall
  in the address range (`0x83000000`, `0x83000400`, ...), the rest sit in the
  CRT. There is **no RTTI** in this executable (4 `.?AV` strings), so the
  ReXGlue approach of walking RTTI vtables would find nothing here.
- Conclusion: indirect calls through vtables are covered; the remaining risk is
  caught at run time by `MW2_TRACE_INDIRECT`, which reports any guest address
  the call table lacks.

What *did* need fixing, and is now automated:

| Problem | Symptom | Fix |
|---|---|---|
| Leaf function containing a jump table | switch cases "outside function" | `tools/fixbounds.py --apply` (205 entries) |
| Over-long jump table reading past its end | garbage labels, one 9 MB "function" | `tools/trim_switch_tables.py` (3 of 1,327) |
| `bdzf` ladder jumping into split functions | `use of undeclared label` after ~25 minutes of compiling | `tools/fix_ladders.py` reads the generated C++ and finds it in seconds (1 function: `0x83911928`) |
| Save/restore helper addresses | recompiler needs 8 addresses | `tools/find_helpers.py` locates them by byte pattern |

`build.sh` runs recompile → `fixbounds` → `fix_ladders` until nothing changes
(bounds only grow, so it converges; it did in 2 passes from a clean config).
Skate3-Port's equivalent files were maintained by hand.

## 4. Build-flag changes made

- `-ffp-contract=off -fno-strict-aliasing` on the generated code: guest
  `fmul` followed by `fadd` must not be fused by the host compiler, and every
  access goes through one base pointer. Pinyon Shift, UnleashedRecomp and
  Skate3 all do this.
- `-march=armv8.2-a+fp16+dotprod` (CMake option `PES_ARMV82`, default on): turns
  every guest `lwarx`/`stwcx.` (a `std::atomic` compare-exchange) into an inline
  LSE instruction instead of a call into the outline-atomics helpers. The app
  checks `/proc/cpuinfo` for `atomics`, `asimddp`, `fphp` before loading the
  library, because a SIGILL inside `loadLibrary` cannot be caught.
- `-Wl,-Bsymbolic-functions`: calls between the generated units never need
  the PLT. Pinyon Shift measured PLT stubs falling from 1.6 % to 0.1 % of
  cycles.
- `tools/verify_android_libs.sh` (from Skate3-Port's build): fails the build if
  a LOAD segment is aligned below 16 KB, which would not load on Android 15.

## 5. Negative findings (do not retry without a new reason)

- **Native `setjmp`/`longjmp`.** Not found. The only `RtlUnwind` callers are
  CRT/SEH helpers (`sub_831E3090` is a two-argument wrapper called from a
  string routine), and no function stores `r14-r31` into a `jmp_buf`-shaped
  area through `r3` with the `stw/std r1,0(r3)` first store the MSVC CRT uses.
  If a run later dies in a non-local exit, search again from the crash site.
- **`[rexcrt]`-style native memcpy/memset.** Left for later. Pinyon Shift found
  its CRT candidates were 0.02-0.05 % of the race each; ranking PES's by static
  caller count needs a device profile first.
- **LTO and PGO.** Pinyon Shift: ThinLTO neutral, PGO 1-6 % per guest thread
  but needs a profile kept in step with the generated code. Not worth the
  build time before the game runs.

## 6. Ideas ranked for when the game boots

1. **Measure on a device** (`simpleperf stat --per-thread`) and compare
   `safe`/`balanced`/`aggressive` by guest instructions per frame, not size.
2. **Fold `.rdata` float loads into literals** (Pinyon Shift: 19,350 sites, −1 %
   host instructions). Needs a patch to the generator; the runtime would have to
   refuse an executable whose `.rdata` differs.
3. **Event-driven `WaitMultiple`** instead of 1 ms polling sleeps (measured in
   ReXGlue PR 368 and Pinyon Shift: audio thread 68 % → 21 % CPU on Linux).
   Check `runtime/kernel/sync_objects.cpp` once threads run.
4. **Flush-mode toggle elision across labels** (−29 % conditional toggles, −6 %
   audio-thread instructions in Pinyon Shift). Generator change.
5. **Lockstep verification**: emit a reference copy of a sample of leaf
   functions and compare registers and stores on-device. The strongest answer to
   "is `aggressive` safe", and nothing in stock XenonRecomp provides it.
6. **A symbol-order file** from a real run, to pack hot generated functions
   together (Pinyon Shift: resident pages 52 → 34 MB).

## Sources

- [XenonRecomp README](https://cdn.jsdelivr.net/gh/hedge-dev/XenonRecomp@main/README.md): config options, jump-table limits, `functions`/`invalid_instructions`/mid-asm hooks.
- [ReXGlue SDK](https://github.com/rexglue/rexglue-sdk) and its [recompilation concepts](https://www.mintlify.com/rexglue/rexglue-sdk/concepts/recompilation) page: `.pdata`-based function boundaries.
- [ReXGlue interview](https://readonlymemo.com/rexglue-xbox-360-recompilation-interview/): Xenia-derived runtime with an AOT backend.
- Local: `pinyon-shift/docs/RECOMP_OPTIMIZATION_SURVEY.md`, `pinyon-shift/site/pages/recompiler.md`, `Skate3-Port/docs/vendored-patches.md`, `Skate3-Port/build-android.sh`, `Skate3-Port/config/skate3_functions.toml`.
