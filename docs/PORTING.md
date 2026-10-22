# PES 2017 → Android: status and what is left

PES 2017 (Xbox 360, Europe, `default.xex`, 32 MB) is recompiled ahead of time
with [XenonRecomp](https://github.com/hedge-dev/XenonRecomp) into C++ that is
built for arm64 with the Android NDK, on the same architecture as `mw2-android`
(the reference port in this workspace): a host runtime stands in for the
console's kernel, GPU (Vulkan) and audio, and the Kotlin app installs the game
files and starts the native library. The second example, `pinyon-shift`
(Forza Horizon on ReXGlue), is the other route to the same end.

This is **not** a finished, playable port. It is the complete, reproducible
front half of one, and a runtime with its MW2-specific code removed.

## Done (and reproducible with `./build.sh`)

| step | result |
|---|---|
| XEX → PE | `pes/default.pe`: retail-encrypted, basic-compressed XEX2 decoded by `tools/xexdump.py`; PPC big-endian, image base `0x82000000`, entry `0x82416708`, `.text` `0x823F0000`+`0x1986684` (25 MB), 73,078 `.pdata` functions |
| Jump tables | `config/pes_switch_tables.toml`: 1,327 tables from XenonAnalyse; 3 over-long ones trimmed by `tools/trim_switch_tables.py` |
| Prologue helpers | save/rest GPR/FPR/VMX addresses located by byte pattern, in `config/PES.toml` |
| Function bounds | 205 leaf functions whose jump tables XenonAnalyse ended early (`tools/fixbounds.py`) plus one `bdzf` ladder (`tools/fix_ladders.py`); `build.sh` loops recompile → fix until nothing changes |
| Recompile | `ppc/`: 0 switch-table errors; 44 undecodable words at the tail of `.text` (data after the last function, `0x83D76674`…) |
| Kernel imports | 281 used by the game; 168 implemented by the runtime, 113 stubbed with a log-once stub (`ppc/stubs_generated.cpp`) |
| Runtime | MW2's engine patches (IW4 netcode fixes, engine log, FOV, etc.) moved to `_mw2_specific/`; `runtime/title.h` rewritten for PES; every runtime source compiles for arm64 |
| Install filter | the installer copies `*.cpk` and `nxeart` from the disc (PES's archives) |
| App | Gradle project: one app, `com.pes2017.recomp`, "PES 2017" |

## Pipeline changes from the research pass

See [RECOMP_RESEARCH.md](RECOMP_RESEARCH.md): `PROFILE=safe|balanced|aggressive`
(register locals; `balanced` is −18 % arm64 code on a sample unit), ARMv8.2
baseline with a CPU check, `-ffp-contract=off`, `-Bsymbolic-functions`,
automatic helper location, and a 16 KB-alignment check after the link.

## On a device (Galaxy S20 FE, Snapdragon 865 / Adreno 650, Android 13)

`tools/deploy.sh [seconds]` rebuilds the runtime on every core (about 20 s when
only runtime files changed), packages the already-built library with
`-PprebuiltNative` (no second compile of the generated tree), installs, launches
and saves `logs-device.txt`. Game files go straight to
`Android/data/com.pes2017.recomp/files/game/` with `adb push` (6.5 GB, about a minute).

Where it stands: the recompiled code boots, the engine starts its threads
(Konami's names: `FileReadProcessThread`, `FileCriFsExecuteMainThread`,
`cobra::compression::job`, ...), D3D creates its device, and the command
processor presents about 60 frames a second. **The title/loading screen renders
correctly** (Camp Nou with the PES 2017 logo) after the memory-model and audio
fixes below.

Fixed on the way, each found from the device log:

| Symptom | Cause | Fix |
|---|---|---|
| indirect calls to functions that exist | the 51 MB function table overlapped the heap (MW2's base 0x84600000) | table moved to 0x10000000 (outside the bank), `static_assert`s |
| `NtAllocateVirtualMemory: out of guest heap (512 MB)` | PES reserves 512 MB at once | far heap 0x20000000-0x80000000, backed on touch |
| critical section at `000101C1` (main thread stuck in D3D init) | kernel data imports left as import records | `ResolveDataImports()`: every variable gets a block, function slots get thunks |
| `KeBugCheck(0)` after a thread exits | `ExTerminateThread` returned | it now unwinds to the thread's entry |
| 42 stubbed imports the boot reaches | not needed by MW2 | `runtime/kernel/pes_imports.cpp` (semaphores, printf family, DPCs, XEX header fields, time, SHA-1, UI) |
| garbage image; 3 shaders "control flow does not terminate" (their microcode read as zeros) | heap and physical arena were separate memory, and the GPU's physical addresses were guessed back to the wrong one once both held data at the same offset | one 512 MB bank mapped at 0x80000000, 0xA0000000 and 0xC0000000 with a single allocator over physical offsets, as on the console |
| loading stops after ~26 MB, black screen | the XAudio render callback was passed its argument, not a pointer to it; it read the engine object's vtable as the object and waited on garbage | the argument is wrapped in a guest word, as the kernel (and Xenia) do |

## Not done — in the order they will block you

1. **Audio handshake.** The render callback now reaches XAudio2's engine object
   but waits on the engine's "done" events, which nothing signals (the engine
   thread waits on another event). Loading proceeds regardless; sound is likely
   silent. Loading is also slow (about 1.3 MB/s), worth profiling once past it.
   D3D's flip handshake (`WAIT_REG_MEM`) still times out at 50 ms now and then.
   The renderer's write-watch only protects the physical-window mapping, so CPU
   writes through the cached window do not invalidate cached textures.
2. **D3D9 / Present hook.** `title.h` has no `T_D3D_Present`/`T_D3D_ArenaWait`,
   so frame pacing and the GPU arena's progress tracking (`runtime/gpu/arena.cpp`)
   are not wired. Candidates found by walking up from the `VdSwap` call:
   `sub_823F98E0` (calls `VdSwap`) ← `sub_82409870` (likely D3D's swap/present)
   ← `sub_83861FA0`/`sub_83863380` (engine side). The device-structure offsets
   MW2's hooks use (`13596`, `10896`) belong to MW2's XDK build and must be
   re-derived for PES's before enabling the hooks.
3. **Xenos GPU coverage.** `runtime/gpu/` translates the PM4 stream and Xenos
   shaders to Vulkan/SPIR-V. It was exercised by one engine; PES (Fox Engine)
   will hit formats, resolves and shader opcodes MW2 never used. Budget the
   most time here.
4. **Game I/O.** PES reads `dtNN_*.cpk` archives through the kernel file API.
   `runtime/kernel/files.cpp` maps `game:\` onto the installed folder; verify
   the asynchronous/overlapped reads and large (1.5 GB) files on Android
   storage. The ISO is 8.7 GB: plan on ≥ 9 GB free on the phone.
5. **Threading and memory.** Fox Engine is heavily multithreaded and uses
   physical memory/large pages; check `MmAllocatePhysicalMemoryEx`, TLS and
   the 4 GiB guest reservation on 16 KB-page devices.
6. **Audio.** XMA decode is in `runtime/apu` (FFmpeg-derived); PES's `.cpk`
   audio and its use of XAudio2 are untested.
7. **Input, saves, UI.** The touch pad and launcher are MW2's FPS layout; PES
   needs a football layout (pass/shoot/through/sprint) and its own save/profile
   handling (`kernel/content.cpp`, `T_Memcard_*` hook is compiled out).
8. **Apk.** `./gradlew :app:assembleRelease` from `android/` once `libmw2.so`
   builds. Needs a Gradle install/wrapper jar, `ANDROID_HOME`, and
   `android/fetch_deps.sh` if you want the custom-driver loader.
9. **Optional:** the multi-title launcher text and strings still say MW2
   in places (`res/values/strings.xml`, Kotlin UI); rename as you go.

## Findings: the front-end text (October 2026)

What made the dialogs and menus draw as empty boxes, and how it was found.

1. **XenonRecomp silently dropped ten instruction kinds** (`vandc`, `vnor128`,
   `vcmpgtuw`, `vaddsws`, `vrfip128`, `lvehx`, `stfsux`, `mulhd`, `rlwnm`,
   `bdnzt`). `logs-recomp.txt` says "Unrecognized instruction" for each, and the
   generated code simply has the comment and nothing else. The one that mattered:
   the game's sin/cos routine (`sub_832106B0`) used `vandc`, so a register kept a
   stale value and the result depended on what ran before it: cos(0) came out
   +-infinity, every UI text matrix got an infinite scale, and the glyphs
   collapsed. The cases are in `XenonRecomp/XenonRecomp/recompiler.cpp` (helpers in
   `XenonUtils/ppc_context.h`); `patches/xenonrecomp-mw2.patch` is regenerated from
   them. After a recompile, check `grep -c Unrecognized logs-recomp.txt`.
   The same fix made the intro movie draw.
2. **`VGT_INDX_OFFSET` (register 0x2102) was ignored.** The UI draws a batch of
   sprites from one vertex buffer, one draw a quad, stepping this offset by four.
   Every glyph draw read quad 0. It is now added to the vertex window and passed
   to `vkCmdDraw` as the first vertex (`vertexOffset`).
3. **Vertex data was served from a stale shadow of guest memory**
   (`gpu::watch::Serve`), so the glyph quads the CPU had just written read back as
   zero. Vertex fetches are copied from guest memory now
   (`kServeVertexShadow` in `renderer_arena.cpp`; turning it back on is the
   performance work).

## Debugging tools added

| Tool | What it does |
|---|---|
| `tools/to_dialog.sh [png]` | relaunch, press Start until the first dialog, screenshot |
| `tools/watch.sh` | follow `game.log`, one line per new error kind (run it under Monitor) |
| `files/dump_frame` | one frame's draws, shader microcode (`tools/xenos_shader.py`), vertex data, constants, register diffs, CPU-evaluated vertex shader outputs |
| `files/draw_range` (`"lo hi"`) | only draw numbers lo..hi of each frame |
| `files/dump_guest` (`"addr len"`) | write guest memory to `files/guest_dump.bin` |
| `files/watch_phys`, `files/watch_guest` | who writes this memory (host call stack per write) |
| `files/trap_inf` | report stores of +-inf (needs `-DPES_TRAP_INF=ON`, slows every store) |
| `tools/dump_phys.sh` | pull the 512 MB physical bank (root) |
| `runtime/gpu/xe/` | Xenia's shader interpreter, vendored with shims, evaluates a vertex shader on the CPU |

Probes at `[T]` level are traces; only faults print as `[E]` (the launcher's
error count was mostly stack dumps).

## The first-run quit, and the main menu

Start -> "Select a Storage Device" -> language -> auto-save notice ->
`Intro/ProcInstall`: that step is a four-state machine (`sub_82F3CBD0`, state at
object+88). It asks the install manager (global, `sub_83105358`) whether a job runs.
With a job it goes to state 3 and sends the "proceed" event; with none it goes
0 -> 1 -> 2 and state 2 sets the main loop's exit flag, so the title ended itself and
the next run began at the first-run screens again (nothing is saved). No install job is
ever started here, so `runtime/pes_hooks.cpp` starts the machine at state 3. The flow
then runs `Intro/DataPackApply/*` and reaches `TopMenu/TopMenu`: the main menu
(Home / Match / Competition / Football Life / Extras) draws and takes input.

### System data now saves

The first-run flow reaches `Intro/ProcInstall` without running
`FirstFlow/ProcSystemDataSave`, so nothing was ever saved and every launch began at
the first-run screens. Three pieces make it persist:

1. `runtime/pes_hooks.cpp` asks for `FirstFlow/ProcSystemDataSave` in place of
   `Intro/ProcInstall` the first time (the procedure switch is `sub_82F00CE8`).
2. `NtSetInformationFile` handles `FileRenameInformation`: the save is written as
   `data.tmp` (+ `data.inf`, `data.png`) and renamed to `data.bin`.
3. Content enumerators list the packages on disk (`kernel::ListContent`); the title
   finds `SYSTEM00000000` by enumerating, not by name. `XamContentCreateEx` keeps the
   title's XCONTENT_DATA in `<package>/.xcontent`.

Launch 2 then loads the save and skips `FirstFlow/ProcStart`. Open: the two
`Intro/SystemSetting/ProcLangInGame*` language screens still appear once per launch (the
language the title saves is not what it compares against), and the streaming install to
`cache:` is not implemented.

## Memory for the match load (October 2026)

The Exhibition kick-off runs the 512 MB bank dry ("MmAllocatePhysicalMemoryEx: out of
physical heap"). The fixes so far:

1. **Physical page size follows the protect flags** (`runtime/kernel/memory.cpp`), as in
   Xenia: 64 KB only with `MEM_LARGE_PAGES`, 16 MB with `0x80000000`, else 4 KB. MW2's
   64 KB rule ran the bank out at the team select (thousands of 320-byte text meshes).
2. **The cached window is the bank too** on Linux/Android (`MapPhysicalAperture`). Only the
   physical and aperture windows were mapped from the bank descriptor, so the image and every
   heap allocation (handed out at cached-window addresses) were invisible to anything reading
   them by physical address. Check: `dump_guest` of `A2000000` and `82000000` now match (the
   image's `MZ` header).
3. **The function lookup table moved out of the bank** to guest `0x10000000` (51 MB back to
   the title). `PPC_CALL_INDIRECT_FUNC` is redefined in the force-included
   `runtime/mmio_hook.h`; runtime code uses `guest::FunctionSlotOffset`. `kHeapBase` is now
   `0x84100000`. Changing `mmio_hook.h` recompiles all of `ppc/` (about 20 minutes).
4. **Guest stacks** are what the thread asks for, at least 64 KB (was at least 512 KB), and go
   back to the bank when the thread exits.

5. **The actual leak: `NtQueryVirtualMemory`.** The CRT malloc maps large chunks itself
   (`sub_82597188` -> `82595DA8` -> `82595B80`, `VirtualAlloc` commit|reserve) and its munmap
   (`sub_82595C00`) releases a block only after `VirtualQuery` says BaseAddress ==
   AllocationBase == the block, State MEM_COMMIT and RegionSize <= size. The stub answered
   "the whole heap" for every address, so every big free failed and 340 MB leaked by the
   kick-off. It now looks the block up (`kernel::FindAllocation`). Bank use at the match load
   fell from 446 MB (full) to about 190 MB, and no allocation fails.
6. **`MmQueryStatistics`** fills X_MM_STATISTICS in pages, as Xenia does (XAPI's
   `GlobalMemoryStatus`, `sub_832D1F90`, reads TotalPhysicalPages, AvailablePages and the
   virtual totals; the stub wrote bytes and left the rest as stack garbage).

`report_memory` also lists the 30 biggest holders by guest call chain (three return
addresses up the back chain).

Not the fix: sending `NtAllocateVirtualMemory` to the far heap (see `docs/HANDOFF.md`).
`touch files/report_memory` prints live bytes per API and per heap.

## The match: a stack the recompiled code left unbalanced (October 2026)

With memory fixed, the load stopped at "Game Tips". A job worker (`sub_83576C40`) deleted
"job 0x10": its callee-saved r30 came back wrong from the job's step. The trail:

1. The step `sub_835770A0` returned with r1 0x3B0 lower than it entered, its own saved frame
   intact (`jobregs` probe). So a callee returned without popping its frame, and every
   epilogue above reloaded r30/r31 from the wrong place.
2. `tools/gen_r1_probes.py ROOT [DEPTH]` generates `runtime/pes_r1_probes.cpp`: a hook per
   function reachable from ROOT that logs a return with r1 moved. It found `sub_834E62A0`,
   whose frame is exactly 0x3B0.
3. Its two jump tables switched on **r12, the table's address**. `tools/trim_switch_tables.py`
   had overwritten `r` (the index register) with the trimmed label count, so no case
   matched, and the recompiler's `default: return;` left without the epilogue.
4. `tools/fix_switch_regs.py` (run by `build.sh` after the trim) reads the real index
   register from each dispatch (`rlwinm rX,rI,2` -> `lwzx`, or `lbzx` on the raw index).
   30 of 1327 tables were wrong: the three trimmed ones, plus 27 where the compiler compares
   one copy of the index and dispatches on another (`cmplwi r10` / `rlwinm r0,r11`).
5. Then 400 calls to `82800D08` "not identified as a function start". `fixbounds.py` ended
   an extended function at the next known start (a `bl` target or `.pdata`), and so
   swallowed functions reached only through vtables. It now ends at the first `blr` or
   outgoing `b` that no internal branch jumps past. Seven entries shrank, and XenonRecomp
   analyses the freed gaps into functions of their own.

After these, kick-off reaches `Match/MatchPostPause`. The match runs: clock, score, radar
and name bars. The 3D view draws white (next item).

`tools/to_match.sh [prefix] [shots] [kickoff|prematch|teams]` reaches kick-off in about
60 s. It waits on the procedures the game logs and recognises the pre-match screen by its
KICK-OFF tile.

## The dark match image (October 2026)

Each of these took part of the brightness or colour away. They're listed in the order they were found, each with the frame-dump evidence.

1. **Pixel centres.** D3D9 (`PA_SU_VTX_CNTL.pix_center` = 0) centres pixels on integers, Vulkan half a pixel on. The viewport is now shifted by half a pixel.
   - Before: the exposure, written by one triangle into a 1×1 R32F target, never landed, because the triangle's edge ran through the Vulkan centre.
   - The scene kept a stale 0.06 instead of about 1.2.
2. **Quad lists** (primitive 13) are expanded to triangles. The crowd billboards use them.
3. **A resolve copy is used for a fetch only if the format matches and the fetch fits inside it.**
   - The pitch's 2048×2048 DXT1 sat where an earlier screen had resolved a 512×128 image, and was drawn from that copy: grey grass.
4. **4× clear rectangles** (2×2 samples) now find the 1× surface they alias (`pitch << min(samples, 1)`) and scale y by 2.
5. **Param gen.** `SQ_PROGRAM_CNTL.param_gen` puts the pixel position in the register `SQ_CONTEXT_MISC.param_gen_pos` names.
   - The translator had no param gen at all, so every screen-space lookup read texel (0,0).
   - It now goes in bits 8–15 of push word 3, applied with constant-index selects. A dynamic index into the temporaries put every pixel shader's registers in memory: 1 fps.
6. **EDRAM aliasing of a depth clear.** PES clears depth (mode DepthOnly) at tile 0 to zero and then MAX-blends a player-shadow mask into the colour surface at tile 0, expecting black.
   - Colour images at the same tile are now cleared too, for zero clears.
   - Before: the mask was drawn over the previous frame and the pitch shading read garbage.
7. **Texture budget.** The app's preference defaulted to 128 MB, which overrode the runtime's sizing (memory / 6, 1 GB here). BC textures are decoded to RGBA on Adreno, so the match thrashed. The default is now 0 ("automatic").

8. **Resolve write-back** (the kits and the pre-match 3D player preview). PES draws each player's shirt, numbers and name during the load and resolves them. The kit textures the match fetches are then made from those bytes in guest memory, but resolves never left the GPU here, so players were black.
   - Small 8_8_8_8 resolves (up to 512×512) are now written back synchronously: submit, wait, read back, and store with Xenos 2D tiling, the R/B swap bit and 8-in-32 endian.
   - A destination also resolved in the previous frame is a per-frame effect and stays GPU-only.
   - Each resolve destination's first use is logged as `resolve: first to …`.

Tools added:
- `tools/xenos_disasm.py`: ALU and fetch disassembler for `DUMP ucode` lines.
- The frame dump now also logs `ps c*` (every non-zero constant the first time a shader appears), `DUMP resolve`, `DUMP   resolve clear`, `DUMP   skipped`, and `samples` for targets, depth and resolve copies, read a frame later.
- It writes the large images to `files/frame_images/*.pnm`.
- `files/skip_ps` (pixel shader hashes to skip) and `files/draw_range` bisect a frame. `files/quad_debug` is a temporary switch.

## Kits, crowd, performance (October 2026, late)

**Wrong kits** (a defender in the keeper's kit, an opponent in ours, varying per load).
- The game composes each person's kit on the GPU during the load: 25 compositions, 10 red, 10 yellow, 3 teal (2 keepers and the referee) and 2 dark (the assistants).
- Each composition is resolved and written back, and the game builds the kit texture in guest memory, reusing the addresses for the next composition.
- A fetch of such an address used the GPU-side resolve copy, which by then could be another person's kit.
- **Rule:** a resolve that was written back is read from guest memory (`Resolved::writtenBack`).
- Two other fixes for black players:
  - Write-backs for a destination resolved in many recent frames are skipped (per-frame effects).
  - Pipelines for small off-screen targets (kit drawing, the crowd atlas) compile synchronously, because a skipped one-time composition is lost for good.
- `tools/kits.sh [dumps] [gap]` checks it. It merges several frame dumps (each player draw's kit texture with its average colour) and reads the load-time `kitcompose` log, so every person is counted on camera or not. More than 10 of a team colour in one frame is a definite error.

**Crowd.** Still missing. Found and fixed on the way:
- Render targets are capped at 4096 rows, not 2048 (the atlas is 128×3328).
- EDRAM depth clears cover only the tiles their rectangle spans.
- Vertex buffers of 128 KB or less are copied whole, since the billboard records are indexed by `index/4` and the corner table by `index mod 4`.

The billboards now cover the stands with sensible UVs (verified with a temporary UV-as-colour shader). What's left is in sampling the atlas.

**Performance**, steady match 31–42 fps → **52 fps (19.2 ms)** on the stock driver:
- Narrowed the whole-buffer copy (1 MB → 128 KB; the command thread was copying megabytes a frame).
- Write-backs of per-frame resolves stop after 8 consecutive frames (each one stalls the CPU until the GPU idles).
- Draw-requested pipelines compile with no backpressure sleep (`QueueItem::urgent`). Prewarm sleeps 25 ms in play, 15 ms otherwise (was 200+ / 120).
- **Pipelines the worker builds for draws are now saved** (`TakeBuiltForDraws`). Before, everything compiled on demand on Android was forgotten each run, so the intro and goal scenes skipped about 1,100 draws every time (players missing, effects popping in).
- `tools/fps.sh [seconds]` logs fps per 600 swaps (`perf: … fps`).

**Turnip** (Mesa, K11MCH1 v26.0.0 R8) loads with libadrenotools (`android/fetch_deps.sh`; `deploy.sh` packages the hook libraries). On this phone it was slower, 29 fps against 49, with the job threads spinning. The package stays installed at `files/drivers/turnip_r8`; the selection was cleared.

**Testing aids:**
- `tools/pad.sh set|tap|clear`: a virtual controller through `files/pad`. User 1 is a second controller.
- `files/skip_ps` and `files/draw_range` bisect a frame. The frame dump logs `vs c*` / `ps c*` constants and kit lines.

## Reproducing

```bash
GAME=../GAME ./build.sh                 # generate ppc/ and build libmw2.so
RECOMPILE_ONLY=1 GAME=../GAME ./build.sh  # generate ppc/ only
```

If the executable ever changes (another region or a title update), delete
the two generated blocks in `config/PES.toml` (`fixbounds`, `fix_ladders`) and
run `build.sh` again; it re-derives them.

## Legal

No game code, data or generated translations belong in version control; the
`.gitignore` excludes `pes/`, `ppc/`, `GAME/` and the build trees. Build only
from a disc you own.
