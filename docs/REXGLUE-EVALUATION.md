# ReXGlue vs our own runtime: evaluation (2026-10-22)

Read-only comparison. Nothing was built or run, and nothing was tested on the phone, so every
statement below comes from reading code and docs. Paths are relative to
`/Users/macdzky/Development/playground/PES2017-RECOMP/`. `SDK` means
`Skate3-Port/third_party/rexglue-sdk`, and `WWE` means `wwe-svr2011-pc/port`.

## Recommendation

**Keep our runtime and borrow pieces. Do not migrate.**

1. ReXGlue's recompiler would not have fixed our two codegen bugs. `sub_8284E0F0` is probably a
   jump-table problem, where it is somewhat better. `82848EE8` is a swallowed vtable function,
   where it is no help, because its vtable scan needs RTTI and PES has almost none (question 1).
2. The shipped 60 fps on a phone does not come from ReXGlue's generic Xenos renderer. WWE gets it
   from a game-specific native D3D renderer that replaces the Xenos emulation (question 3). We
   would have to build the equivalent for PES, and we would build it on our own runtime.
3. The migration cost is large and the benefit is mostly things we already have (question 4).

Revisit only if we decide to build a native D3D9-level renderer for PES (see "Bigger bet").

## 1. Jump tables and vtable-only functions

**Jump tables: ReXGlue's detector is better than XenonAnalyse.**
`SDK/src/codegen/function_scanner.cpp` (`detect_jump_table`, `detectJumpTable`, `scanForBounds`,
lines ~170-640 and ~1280-1560):
- It handles four table encodings (absolute `lwzx`, computed `lbzx`+shift+add, byte offset and
  short offset `lhzx`).
- It tracks the index register backwards through `rlwinm`/`slwi` and through `mr`/`or`/`and`/`xor`
  copies (line ~1532).
- Its bounds scan reads past an EA-style `cmplwi; ble table; b default` pattern (line ~1302).
- A `lis`-less `lwz`+`bctr` is classified as a vtable call, not a switch (line ~787).
- It takes manual `[[switch_tables]]` overrides (`config.cpp:264`) and runs inside a
  discover/merge/gap-fill/validate pipeline (`phase_*.cpp`). `phase_gapfill.cpp` turns freed
  gaps into functions.
- That is the same set of cases our `tools/fix_switch_regs.py` (27 of 1,327 tables with a
  compare on one copy of the index and a dispatch on another), `tools/find_missed_switches.py`
  (stores between the guard and the `bctr`) and `tools/fixbounds.py` patch after XenonAnalyse.

It does not obviously handle a store between the guard and the `bctr`, which is what
`find_missed_switches.py` exists for. I did not run it on PES, so "better in design" is not
"proven on this binary".

**Vtable-only functions: ReXGlue does not help PES.**
`SDK/src/codegen/vtable_scanner.cpp` finds vtables only through MSVC RTTI. It scans `.rdata` for
Complete Object Locators whose type descriptor starts with `.?AV` or `.?AU`, then promotes the
vtable slots to functions (`phase_discover.cpp:260-327`, authority `VTABLE`). `pes/default.pe`
contains **4** `.?AV` strings in 34 MB. Konami built it without RTTI, so the scanner would find
almost nothing. WWE and Skate 3 presumably ship RTTI, which is why it worked for them.

The `82848EE8` case, a function swallowed because a neighbouring function was extended, comes
from function-bound inference, not from vtable discovery. ReXGlue's `FunctionGraph` has
authorities (`PDATA`, `CONFIG`, `VTABLE`, `GAP_FILL`) and multi-entry "chunks", but that is
still heuristic. Our fix (`fixbounds.py` ending at the first `blr` or outgoing `b` that no
internal branch jumps past) is of the same kind. The better generic fix for PES is a vtable scan
without RTTI: find `.rdata` runs of 4-byte aligned pointers into `.text` that are function starts
or at least land on a prologue. Neither toolchain has that.

## 2. XAM and kernel completeness

| | ReXGlue SDK | Our runtime |
|---|---|---|
| Size | `src/kernel`: xam 6.7k + xboxkrnl 9.2k lines, ~440 implemented exports and ~2,400 `REX_EXPORT_STUB` lines | `runtime/kernel/`: 8.3k lines, 231 `PPC_FUNC(__imp__*)` imports, written for the imports PES and MW2 use |
| `XamShowKeyboardUI` | `SDK/src/kernel/xam/xam_ui.cpp:339-470`: ImGui modal dialog and a headless fallback, completed through `xeXamDispatch*`. It broadcasts `XN_SYS_UI` true/false around dialogs (lines 53-145). | `runtime/kernel/pes_imports.cpp:565-680`: native Android dialog, a pending overlapped (`X_ERROR_IO_PENDING`), completion, cancel through `dwExtendedError`, `XN_SYS_UI` closed 500 ms later, and the newest call replacing an older one. It is at least as faithful as theirs. |
| Notifications | `xam_notify.cpp`, 125 lines | `runtime/kernel/xam.cpp:178-280` (listeners, `XNotifyGetNext`, `PostNotification`) |
| Content and saves | `xam_content*.cpp`, `system/xam/content_manager` (468 lines in `xam_content.cpp`) | `runtime/kernel/content.cpp`, `durable.cpp`, `profile.cpp`, working on the phone with PES saves |
| Extras | party, voice, NUI, avatar, net, XMP app, an `apps/` message dispatcher | not needed by PES |

Verdict: ReXGlue's kernel is broader and its semantics are good. It is Xenia's, and was already
our reference for the XAM UI semantics. Ours is narrower but verified against PES on the
device. Most of our recent XAM bugs came from MW2-era stubs, and the fix is to diff those stubs
against `SDK/src/kernel/xam/*` and `xboxkrnl/*`. It does not call for a runtime swap. The
audit is cheap (see the piecemeal list).

## 3. Vulkan on Android/Adreno, and what WWE does for phone performance

- ReXGlue's own Vulkan path is the Xenia-derived emulated renderer: `SDK/src/graphics/vulkan/`
  (command processor, render-target cache, texture cache, pipeline cache, shared memory) and
  `SDK/src/ui/vulkan/`. It emulates the Xenos from PM4, as ours does. The SDK has a
  `surface_android.cpp`, but upstream Android support is thin: **WWE carries a 9,255-line patch
  to the SDK** (`WWE/patches/rexglue-sdk-svr2011.patch`, 106 files) that adds `main_android`,
  posix fibers, filesystem, memory and threading, the Vulkan presenter changes and more.
  A 3,169-line patch to plume (its native renderer's graphics library) comes on top.
- The "experimental Vulkan" in WWE's README is the *native renderer* on Vulkan. Its Android
  build ships and runs at 60 fps on a Fold 7 (Adreno 750 class). A Fold 7 GPU is much faster than
  the S20 FE's Adreno 650, so that number does not transfer.
- **Why WWE reaches 60 fps:** it replaces the Xenos emulation for the 3D scene.
  `SDK/src/graphics/native_guest_renderer.cpp` registers a game-supplied "native guest output
  renderer" and suppresses the emulated draws while it is active (`native_render_suppress_*`
  cvars; the cvar text says the emulated postfx chain "paces the pipeline (~half the achievable
  frame rate)"). WWE's implementation is `WWE/src/native/` (8.2k lines: `native_renderer.cpp`,
  `backend_vulkan.cpp`, `native_hooks.cpp` on 37 identified D3D device functions). It converts the
  game's shaders ahead of time with XenosRecomp to HLSL/SPIR-V, and uses 467 shaders found at the
  D3D API (`WWE/docs/native_renderer_phase1.md`). All of that is SvR-specific.
- Mali is unsupported (`wwe-svr2011-pc/docs/MALI_GPU.md`). The driver tooling for Adreno
  (libadrenotools, Turnip packages) lives in `WWE/android/java/.../Drivers.java`. We already use
  libadrenotools, and our Turnip R8 test was slower than the stock driver.
- The generic emulated Vulkan path has no evidence of phone-level performance. Our own renderer
  (`runtime/gpu/vulkan/`, ~19k lines with `runtime/gpu/`) already does the same job and is
  tuned on the Adreno 650 (57-60 fps at 0.75 scale).

## 4. Migration cost, and what to lift instead

### Cost of a migration (estimate: weeks, with a long tail)

Redo or re-verify:
- Codegen output and build: ReXGlue has its own recompiler, config (`manifest`, `switch_tables`),
  generated-code ABI and project layout. `build.sh`, the fix scripts, `config/PES*.toml`
  (1,327 switch tables, 205 bound fixes) and the ~30 min full rebuild all change.
- All PES hooks in `runtime/pes_hooks.cpp`, `runtime/pes_debug.cpp`, `runtime/kernel/pes_imports.cpp`.
- Everything in `docs/PORTING.md`: the `NtQueryVirtualMemory` leak, the memory window and
  function table at `0x10000000`, the XAudio callback ABI, depth clear value, pixel centre, quad
  lists, EDRAM aliasing and the resolve write-back (what makes kits correct). The Xenia-derived
  renderer may already have some of these right, but each needs re-verifying. Its 3D path is
  more general and probably heavier than ours on Adreno 650.
- The Android layer: the SDK needs the 9k-line patch WWE carries (we would have to write or
  copy it), plus our touch input and keyboard dialog, scene scale and the pipeline cache
  and shader cache handling.
- No performance data suggests the generic ReXGlue renderer beats our 57-60 fps. The expected
  result is a regression, then rework to tune it.

Benefits: a maintained recompiler, a broader kernel, and a shared codebase with the Skate 3 and
WWE ports. Those are real but small compared with the cost.

### Five most valuable pieces to lift (in priority order)

1. **Jump-table detector** → our codegen pipeline.
   `SDK/src/codegen/function_scanner.cpp` (`detectJumpTable`, `scanForBounds`: index-register
   tracking through copies, the four encodings, the default-branch skip). Port the logic into
   `XenonRecomp/XenonAnalyse/` or as a replacement for `tools/find_missed_switches.py` and
   `tools/fix_switch_regs.py`. Cross-check it against our 1,327 tables, and use it to find
   what `sub_8284E0F0` is missing.
2. **Function-graph and gap-fill logic** →
   `SDK/src/codegen/function_graph.cpp`, `phase_gapfill.cpp`, `phase_validate.cpp`
   (`looksLikeExceptionData`, `splitRegionOnTerminators`, chunk handling). Use as a model for
   fixing function bounds in `tools/fixbounds.py` and for a non-RTTI vtable scan (the part
   `vtable_scanner.cpp` does with RTTI, redone by pointer-run heuristics). This is the one that
   addresses `82848EE8`-type bugs.
3. **Kernel/XAM audit and imports** →
   `SDK/src/kernel/xam/xam_ui.cpp` (message box, keyboard, XN_SYS_UI timing),
   `xam_notify.cpp`, `xam_content.cpp`, `xam_user.cpp`, `xam_enum.cpp`, and
   `SDK/src/kernel/xboxkrnl/xboxkrnl_threading.cpp`, `xboxkrnl_memory.cpp`, `xboxkrnl_io.cpp`.
   Diff each against `runtime/kernel/xam.cpp`, `pes_imports.cpp`, `sync*.cpp`, `memory.cpp`,
   `files.cpp` for MW2-era stubs and wrong return codes. Cheapest and the one most likely to
   prevent the next "stub semantics" bug.
4. **Xenos graphics reference** →
   `SDK/src/graphics/vulkan/render_target_cache.cpp`, `texture_cache.cpp`, `pipeline_cache.cpp`,
   `primitive_processor.cpp`, `SDK/src/graphics/pipeline/shader/*`, `xenos.cpp`.
   Use for the resolve, EDRAM and texture-format behaviour we are still finding by bisecting
   (`runtime/gpu/vulkan/renderer_resolve.cpp`, `renderer_targets.cpp`, `texture_formats.cpp`),
   and for the crowd that is still missing. Use as a reference, not as code to paste.
5. **WWE's native-renderer architecture** →
   `wwe-svr2011-pc/port/src/native/` (`native_renderer.cpp`, `backend_vulkan.cpp`,
   `native_hooks.cpp`), `wwe-svr2011-pc/port/docs/native_renderer_phase1.md`, `phase2.md` and
   `d3d_map.csv`, plus `SDK/src/graphics/native_guest_renderer.cpp` for the "suppress the
   emulated draws" hook. This is the "bigger bet" below; only the design is lifted. Our
   `docs/d3d9-seam.md` says the library is not inlined, so the same hooking could work.

Also worth a look but not top five: `wwe-svr2011-pc/docs/MALI_GPU.md` (feature gaps if Mali
phones ever matter) and `WWE/android/java/.../Drivers.java` (driver management).

### Bigger bet (optional, not part of the recommendation)

A native D3D9-level renderer for PES, the WWE way: map PES's device library, hook the ~40
functions that cover most calls, convert shaders ahead of time, and draw them through our Vulkan
renderer. It is the only path in the evidence to a large fps gain on a phone. It means mapping a
D3D library nobody has symbols for, converting every shader, and keeping the cases (menus,
resolves, shadow maps) that need the emulated path. That is a project of its own. It does not
need ReXGlue, and nothing here suggests ReXGlue would make it easier.

## Caveats

- Not run: ReXGlue's codegen has not been tried on PES's `default.xex`, so its jump-table
  advantage is from reading, and its vtable result is inferred from the 4 `.?AV` strings.
- Not read in depth: the SDK's D3D12 backend, audio, XMA, and the Skate 3 port itself.
- The Fold 7 comparison is the README's claim. The `PERF_LOG.md` run on the Fold shows 58.4 fps
  average with 11 frames over 51 ms (the "60 fps" is near, not locked).
