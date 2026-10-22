# Handoff: PES 2017 Android port (2026-10-21, end of day)

This picks up from a Claude Code CLI session. Everything is under
`/Users/macdzky/Development/playground/PES2017-RECOMP/pes2017-android/`. There is no git repo,
so every change is uncommitted. Details and evidence for every fix are in
`docs/PORTING.md`; this file covers what you need to continue.

## Setup

- **Phone:** Galaxy S20 FE (SM-G780G, Snapdragon 865 / Adreno 650, Android 13), USB, serial
  `RR8RB04X2SV`. It is rooted with Magisk (`adb shell su -c ...`). The user sometimes leaves
  other apps open (TikTok), which causes memory pressure; and heat above about 68 °C costs fps.
- **Package:** `com.pes2017.recomp`. Game files are already on the phone in
  `/sdcard/Android/data/com.pes2017.recomp/files/game/`.
- **Build and deploy (runtime only, about 1 min):** `tools/deploy.sh [secs]`.
  - It rebuilds `build-android/libmw2.so`, packages it through Gradle with `-PprebuiltNative`
    (including the libadrenotools hook libraries), installs it and launches it.
- **Full rebuild (about 30 min):** needed after a change to `ppc/`, `runtime/mmio_hook.h` or
  `ppc/ppc_recomp_shared.h`.
  - Regenerate with `RECOMPILE_ONLY=1 GAME=../GAME ./build.sh`.
  - Then build with `PYENV_VERSION=3.10.14 ninja -C build-android mw2`.
- **Logs:**
  - `tools/logtail.sh run [regex]` reads the current run of `files/game.log`.
  - Native crashes: `adb logcat -b crash`.
  - The `fault addr 0xa2000000` crash still at the top of that buffer is old, from early on 21 October.
- **macOS:** no GNU `timeout`, bash 3.2 (no associative arrays), BSD awk (no `strtonum`).
  Use python3 for parsing.

## State right now

| Area | State |
|---|---|
| Boot → menus → Exhibition → match | works; `tools/to_match.sh` reaches kick-off in about 60 s |
| Match rendering | correct: pitch, lighting, shadows, all kits (verified 10 red, 10 yellow, 3 teal, 2 dark) |
| Crowd | **missing** (the user accepts that for now) |
| Gameplay fps | **57–60 fps** with the scene at 0.75 scale (960x540, the Android default) |
| Cutscenes and close-ups | about 30 fps. **The game caps these at 30** (measured: exactly 29.9 fps, 33.5 ms). The user wants a 30/60 option for them later |
| Cutscene flicker | **reported by the user, not reproduced yet** (see next steps) |

## Done this session (all in PORTING.md)

- **Memory and stability:**
  - Fixed the match-load out-of-memory (an `NtQueryVirtualMemory` leak).
  - Fixed jump tables using the wrong register (`tools/fix_switch_regs.py`).
  - Fixed function bounds (`fixbounds.py`).
  - Mapped the cached window onto the bank.
  - Moved the function table to `0x10000000`.
- **Rendering:**
  - Depth clear value.
  - Pixel centre.
  - Quad lists.
  - Param gen.
  - EDRAM depth-clear and colour aliasing.
  - Resolve write-back, which is what makes kits work.
  - Written-back resolves are read from guest memory (the wrong-kits fix).
- **Performance:**
  - Narrowed the whole-buffer vertex copy (128 KB).
  - Capped write-backs per destination (12, or 8 in consecutive frames).
  - Pipeline compiles: urgent ones skip backpressure, and pipelines built for draws are saved
    to the shader cache.
  - **Scene render scale** `MW2_SCENE_SCALE` (default 0.75 on Android in `runtime/android/perf.cpp`).
    It applies only to surfaces 1152+ wide. The fractional scale flows through `Target::scale`,
    `Resolved::scale`, `HostOf()`/`Scaled()`, push constants at `kScaledPushOffset` (mask plus
    two floats), and the translator's `GuestSize` and param-gen scaling. Overrides:
    `files/scene_scale` (for example 0.5 or 1), and an env var.
  - **Vertex range reuse within a submission** (`g.vertexCopies`, guarded by the page watch).
- **Turnip driver:**
  - Mesa Turnip R8 is installed at `files/drivers/turnip_r8` and loads through libadrenotools.
  - It was **slower** (29 fps against 49), so it is deselected. To select it, write
    `driverDirectory`/`driverLibrary` into `shared_prefs/mw2.xml` with root, with the app stopped.
- **Pixel shader depth export (oDepth, export 61):**
  - Now translated (`m_fragDepth`, DepthReplacing). About 105 cutscene draws per scene were
    skipped as "not translated".
  - **Deployed but NOT verified.** Check that "shader not translated" is gone, and that there is
    no crash or visual damage in cutscenes.
- `kCacheVersion` is now 11. The first run after a version bump recompiles shaders.

## Test tools

- `tools/to_match.sh [prefix] [shots] [kickoff|prematch|teams]`
- `tools/fps.sh [secs]`: logs one `perf: N fps … write-backs` line per 600 swaps.
- `tools/kits.sh [dumps] [gap]`: kit colours per player from frame dumps and load-time
  compositions. More than 10 of a team colour in one frame is a definite error.
- `tools/pad.sh set|tap|clear`: a virtual controller through `files/pad`. User 1 is a second
  controller.
- `tools/owngoal.sh [run-secs]`:
  - Kicks off, runs left to our goal, then **LT + A toward it** (the user's latest recipe, still
    untested).
  - Screen-records 28 s to `/tmp/og.mp4`.
  - Earlier recipes (RB tapping) scored once out of about 6 tries.
- `tools/flicker.py video.mp4`: flags one-frame flashes or brightness pops. 0 flagged so far,
  but no successful goal recording has been analysed yet.
- `tools/sample.sh [n]`: GPU busy and clock plus the top threads, with root.
- `simpleperf`, with root:
  - Write a script to `/data/local/tmp/rec.sh` that `cd`s to `/data/local/tmp` first, because
    the shell's working directory is read-only.
  - Use `-p <pid> --call-graph fp`.
  - Report with `simpleperf report -i … --comms "<thread>" --sort symbol --children`.
- Frame dump: `touch files/dump_frame`. It writes `DUMP …` lines plus
  `files/frame_images/*.pnm`. `files/draw_range` and `files/skip_ps` bisect a frame.

## CAPTURE button (added after the handoff)

A small CAPTURE button sits left of MENU in the game. Tapping it writes `files/capture_request`. The renderer
(`Swap()` in `renderer_resolve.cpp`) then logs the last 240 frames as `swap:draws:ms` under `capture:` and
touches `dump_frame` so the next frame is dumped. `tools/capture.sh` summarises it (frame-time histogram,
draw-count jumps, slow frames); `tools/capture.sh press` triggers it from the shell. Seen so far in a goal
cutscene: frames alternate 33/16/33 ms, an uneven 30 fps cadence that may be what reads as flicker.

## Next steps (in the user's priority order)

1. **Cutscene flicker:**
   1. Make `tools/owngoal.sh` score reliably. Check `/tmp/og_near.png`, tune the run time, use LT + A.
   2. Run `tools/flicker.py /tmp/og.mp4`, and look at `/tmp/flicker/hit_*.png` (prev / frame / next).
   3. Suspects:
      - Resolve copies picked from the wrong frame slot.
      - The vertex-copy reuse (`g.vertexCopies`); turn it off to compare.
      - Write-back caps.
      - The new oDepth path.
2. **Verify the oDepth change** (see above).
3. **30/60 option for cutscenes:**
   - The cap is the game's own frame interval.
   - Find the guest's present-interval setting: D3D `PresentationInterval` or a `VdSwap`
     interval argument. Then patch it through a `GUEST_HOOK`, behind a launcher option.
4. **Remaining performance:**
   - Gameplay sometimes dips to 54–56.
   - Next candidates: fold the EDRAM clears into render-pass load ops (pinyon's approach,
     −1.6 to −2.6 ms); asynchronous BC decode; `Surface.setFrameRate(60)`.
   - The "pacing:" log line in `gpu.cpp` VBlankWorker is broken (it always prints "1 swaps");
     fix it or drop it.
5. **Crowd:**
   - The billboards are placed correctly, and their UVs were verified with a temporary
     UV-as-colour shader.
   - What is left is sampling the atlas (`resolve 06C50000`, 128x3328; shader `ps B4BBEA…`
     kills when `1 - z*w < c255.y`).
6. **Clean-up later:** the `DUMP` diagnostics are cheap while idle; `files/quad_debug` was
   removed; `pes_debug.cpp` holds only the helper.

## Cutscene flicker on players only (user report, 2026-10-21)

Only the players flicker in cutscenes, never the surroundings. That points at dynamic or skinned vertex data
and not at shaders or resolves. First suspect: `g.vertexCopies` reuse in `renderer_arena.cpp`, which trusts the
page watch (`gpu::watch::Unwritten`) to say the guest has not rewritten a vertex range. A missed write would
draw last frame's pose. A/B switch: `touch files/no_vertex_reuse` (polled every 20 swaps, no relaunch);
`rm` it to turn reuse back on. Status: switch deployed, not yet judged by the user.

Cutscene flicker update: `no_vertex_reuse` made no difference (user), so vertex reuse is not the cause (it is back on).
The CAPTURE button now dumps 6 consecutive frames; `tools/diffdraws.py` lists the draws (by vertex/pixel shader pair)
that appear or vanish between them. Needs a capture taken during a player cutscene (goal, foul close-up): the
kick-off intro has no player cutscene.

## Mid-match freeze (user report, 2026-10-21 late)

Symptom: players and everything freeze, the ad boards keep animating. CAPTURE taps 3 and 4 of that run were taken
while frozen. The frame ring at those taps: 240 frames, every one with exactly 457 draws at 16 ms — the renderer
presents a static scene at 60 fps while the game's simulation is stuck (normal play varies 330-400 draws).
No GPU wait timeout, arena or fence message in the log around it. The main game threads (guest 34/35/36) were
spinning in `NtYieldExecution` (`lr 832D22D0`, `r4 2014F7C0` in common), i.e. a busy-wait, not a blocked wait;
the cross-thread stack dump is compiled out on Android so no backtraces.

Two hypotheses:
1. The freeze was caused by the earlier heavy CAPTURE bursts (taps 1 and 2 ran the full frame dump, ~2 s per frame,
   8 MB of log and ~500 MB of images per frame, on the GPU thread). Fixed: a CAPTURE burst is now header-only
   (`g_dumpHeaders`); full dumps are only for `touch files/dump_frame`.
2. A real game-side deadlock (a job the main threads spin on never completes). CAPTURE now also logs
   `spin:` lines: each yield-spinning thread's guest call chain (`kernel::DumpYieldStacks`, `pes_imports.cpp`).
   Next time it freezes, tap CAPTURE once and read `tools/logtail.sh run "spin:"`.

Freeze update: after the header-only CAPTURE, the user tapped CAPTURE several times in a match and nothing froze.
So hypothesis 1 (the heavy full-frame dumps on the GPU thread) is the likely cause; the `spin:` logging stays in
case a freeze shows up again without any capture.

## Live watcher (tools/live.py) and the second freeze

`tools/live.py` follows the phone's log in near real time. The game prints `tele: fps N worst M draws a-b same K`
once a second. During a match the watcher flags a frozen scene (same draw count for 150 frames) or a >100 ms
stutter, and on a flag or a CAPTURE tap it saves the last 30-45 s of a rolling phone-side screen recording
(`tools/live.sh`, 4 x 15 s segments) to /tmp/live/<time>/, runs `flicker.py` on it, and for a freeze also saves a
simpleperf profile and the scheduler object. Use it with the game running: `python3 tools/live.py`.

Second freeze, caught live at 22:34 (draws stuck at 358, fps dropped 50 -> 40 first): the main thread keeps
presenting (~7% CPU), but the game-logic threads 34/35/36 sit in `sub_8354A958`, the job scheduler's idle loop
(`NtYieldExecution` from `8354AA7C`, ~20% CPU each), so no task is being run. Not out of memory (281 of 512 MB), no GPU wait
timeout, not the clock (the time bundle is updated from the vblank thread). Scheduler object at `2014F7C0`
(vtable 82258CA8, fields +1F0..+208 = 7, 0xD, 201FFB40, 2014FA30, 3, 3, 3). Next: compare this against a healthy
snapshot of the same object, and find what makes the scheduler idle while tasks are still pending (a task marked
running by a thread that is waiting on an event no one signals, or a lost wakeup).

Third freeze (22:40, before kick-off, nothing presenting; the tele line stopped at swap 2271): simpleperf showed guest
thread 11 (a game memory-pool thread) inside `NtAllocateVirtualMemory -> kernel::AllocateGuest -> Heap::Alloc -> memset`,
with ~20% of its samples in `art::SignalChain::Handler`/`sigreturn` (page faults on write-watched pages), while threads 35/36
spun in the scheduler idle loop (`sub_8354A958`) and the main thread was nearly idle. Hypothesis: the zeroing memset of a
reused block into write-watched pages (one fault + 3 mprotects per page) is extremely slow or livelocks with the GPU
thread re-arming the watch. Deployed: `Heap::Alloc` now logs `memory: zeroing N KB ... took M ms` for any zero >= 100 ms.
Next freeze: read that line (`tools/logtail.sh run "zeroing"`). Likely fixes: skip the zeroing when the block was never
written (fresh from the top), or loosen the watch for the range before the memset (`gpu::watch::WillWrite`).

Fourth freeze (in a match, match clock stuck at 0:43, draws stuck at 371 for 3000+ frames, still presenting, phone at 72 C and
fps sliding 60 -> 32): same signature as the second. No slow-zeroing line, so the allocator is not it. Threads 34/35/36 idle in
`sub_8354A958 -> sub_83546950` (scheduler idle), main thread ~7% CPU. `live.py` now keeps a ring of 8 snapshots of the scheduler
object (2014F7C0, 0x240 bytes) taken every ~4 s during a match in /tmp/live/snap/s00..s07.bin, and runs the freeze profile from a
pushed script (the inline version silently produced no file). Next freeze: diff the frozen object (saved as
scheduler_2014F7C0.bin) against the snapshots. Also suspect heat: both in-match freezes came after fps had been sliding.

Fifth freeze (clock stuck at 6:23, 74 C): scheduler object `2014F7C0` byte-identical to a healthy snapshot (not the scheduler);
game clock advancing (bundle tick 229 s -> 235 s); events set by the sim/worker threads (000100A8, 000100B4, 000100C0,
00010428, 000104C0, 00010A0C) all stopped growing together. Kernel waits re-check every 2 s, so a plain lost wakeup should self-heal.
Heat hypothesis (all in-match freezes followed a slide in fps at 72-75 C): `files/scene_scale 0.5` set for a cooler A/B.
If it still freezes cool: hook `sub_8354A958` (scheduler idle loop) to log the pending task list, and read what the Match tick task
waits on; also try with the write-watch / vertex shadow off.

## Match freeze: root-cause lead (2026-10-22 early) -- a corrupted function pointer in the sim task

Freeze again at render scale 0.5 (clock 20:58, 71 C), so GPU load/heat is not the cause. Every in-match freeze run
(g3/g4/g5 and the earlier ones) logs exactly two reports in the second before the draw count locks:
  `indirect call to 8284EB88` (or `8284EBEC` in other runs) -- "inside the code range but not a function start" -- then
  `indirect call to BF800000` (the float -1.0 used as an address).
Both come from the same task call chain: scheduler `8354A958` -> 83536098 -> 835359F8 -> 825B6028 -> 825B8BD8 -> 82A59458 ->
82939200 -> 82938F20 -> ... -> 82947438 -> 827CD0C0 -> 82852050 (first) and 82939200 (second). The runtime skips the bad call and
carries on, so that task never finishes and the sim stops (scheduler object identical to healthy, clock fine, no GPU/memory issue).
8284EB88/8284EBEC are inside `sub_8284E0F0`, as case labels of its own jump table (they appear as data at 8284EACC..8284EB80), not
function starts, so a call to them is garbage, not a missing function. BF800000 as a pointer says an object/vtable slot holds float data.
=> Memory corruption of an object (or a recompiler bug in a vector/float store or load), not a scheduling problem.
The pre-kick-off freeze of 22:40 had no bad call: a different problem (guest thread 11 inside AllocateGuest/memset with a
SIGSEGV storm); the zeroing-time log did not fire in later runs.
Next (needs a full regeneration, ~30 min): make `PPC_CALL_INDIRECT_FUNC`'s failure path in `ppc/ppc_recomp_shared.h`
(generated by tools/genshared.py) report the guest registers (r3..r12, lr, ctr) and the 4 words at [r3] and [r3+...] so the corrupted
object can be found; then `files/watch_guest` on that object's address to catch the write that corrupts it. Also consider making the
reporter abort the task (unwind to the scheduler) instead of continuing.

## Keyboard (name entry) -- added 2026-10-22

`XamShowKeyboardUI` was a stub that cancelled at once, so no keyboard ever showed for names (Master League manager name etc.).
Now: `runtime/kernel/pes_imports.cpp` -> `android::ui::ShowKeyboard` (`runtime/android/jni.cpp`) -> `NativeListener.onKeyboard`
(`GameActivity.kt`, an AlertDialog with an EditText and the phone's keyboard) -> `NativeBridge.nativeKeyboardResult` -> the answer is
written into the game's Buffer as big-endian UTF-16 and the overlapped completed. One dialog at a time; a newer request takes over
the answer and the older one is cancelled. Log lines: `keyboard: flags ... buffer ... overlapped ...` and `keyboard: answered "text"`.
Verified end to end: the typed name shows in the Manager's Name row and OK accepts it.
Two things made the game take the answer (found by hooking the completion, sub_83114F18, and by reading ReXGlue's xam_ui.cpp):
(1) the async call must mark its XOVERLAPPED as running (InternalLow = 997) when it starts -- a zero reads as "finished with nothing";
(2) XN_SYS_UI notifications: param 1 before the dialog, param 0 about 100 ms AFTER the overlapped completes (the title discards the
result when it did not see the UI open); on a cancel the call completes with result 0 and extendedError 1223, as Xenia does. The phone's keyboard itself may not draw on top
when a gamepad is attached (the dialog and text field work, `adb shell input text` fills it).

## Bad-call register report -- built 2026-10-22

`MW2ReportBadIndirectCall(target, &ctx, base)` (generated by tools/genshared.py into ppc/ppc_recomp_shared.h, defined in crash.cpp) now prints
guest lr, r3..r31 and the words behind pointer-like registers, and the guest call chain. Installed. Wait for the next match freeze, then
read `tools/logtail.sh run "indirect call"` plus the lines after it. CMake: the mw2 target force-includes <cstdint> for C++.

## Match freeze: ROOT CAUSE FOUND (2026-10-22) -- a jump table the analyser missed

The register report (`guest lr 8284E0F8`, `r12 8284EAC4 -> 8284EC14 8284EC14 8284EBEC ...`) showed the "indirect call to 8284EBAC" is a
`bctr` jump-table dispatch inside `sub_8284E0F0` (table at 8284EAC4, 49 labels, index r10, default 8284EBEC). XenonAnalyse did not
recognise it because four `sth` stores sit between the `cmplwi`/`bgt` guard and the `lis/rlwinm/addi/lwzx/mtctr/bctr` sequence, so the recompiler
emitted `PPC_CALL_INDIRECT_FUNC(ctr)`; the runtime skipped the call, the task never finished, and the sim stopped (`BF800000` was fallout).
Fix: `tools/find_missed_switches.py` scans the image for such dispatches and `build.sh` appends them (config/pes_switch_extra.toml) to
config/pes_switch_tables.toml after the analyser. It found two: 8284EAC0 (this one) and 8315947C (in 83159120, 10 labels, index r3).
A skipped candidate: bctr 838F6EBC in 838F6D40 (no guard found) -- not investigated.
Needs the regenerated ppc/ plus a full ninja build (~30 min); then play a few matches with `python3 tools/live.py` running to confirm no freeze.

## Second freeze cause: vtable-only functions swallowed by an extended bound (2026-10-22)

After the 8284E0F0 table fix, a cutscene froze again (731 draws) with `indirect call to 82848EE8`: `r10` was a vtable, 82848EE8 a real function
(`lwz r11,4(r3); li r10,0; ...`) that sat after the `blr` of sub_82848DE8, whose fixbounds size 0x22C stretched over it AND over the jump
table at 82848F0C that belongs to it. fixbounds took the nearest KNOWN start, and vtable-only functions are not known starts.
Fix: `tools/fixbounds.py` now adds every code pointer found in the data (not a jump-table label, preceded by blr/b/padding) to `starts`
(9405 found). The stored fixbounds block in config/PES.toml was cleared (backup /tmp/PES.toml.bak) so build.sh derives all bounds again.
Needs a full regeneration (5 passes) plus ninja, then re-test.

## Ball blink in a frozen cutscene (user capture, 2026-10-22)

With the sim frozen, a burst of screenshots shows the ball's shading flip between bright white and dull blue-grey (states ABABAA... over 24
shots) while everything else is static, so it is renderer-side. Suspect: the write-back cap in renderer_resolve.cpp (a destination written
back 12 times, or 8 in consecutive frames, is then left on the GPU; a texture flagged `writtenBack` is read from guest memory). Test switch:
`touch files/no_writeback_cap` (polled every 20 swaps) makes every small 8_8_8_8 resolve write back, as before the cap.
live.py also stopped re-requesting a capture every second during a freeze (it had made 65 capture bursts).

## Image quality and smoothness (2026-10-22)

- **FSR 1 upscaler** in the presenter (`runtime/gpu/vulkan/upscaler.cpp`, shaders in `runtime/gpu/vulkan/ffx/` copied from ReXGlue/Xenia):
  EASU then RCAS from the 1280x720 frame to the window's picture size, then a 1:1 copy; falls back to the old bilinear blit if it
  cannot run. Off: `MW2_UPSCALER=bilinear` or `touch files/upscaler_off` (live). `MW2_FSR_SHARPNESS` (stops, default 0.2).
  Measured cost: none visible (on/off within noise). Present images got `VK_IMAGE_USAGE_SAMPLED_BIT`.
- **Surface no longer shrunk**: `Prefs.resolutionScale` defaulted to 0.7 (MW2) -> the 1280x720 frame was shrunk to 896x504 on this
  HD+ phone before the compositor stretched it. Default now 1.0.
- **Multisampling**: the app's "Smooth edges" switch never worked (it unset MW2_NO_MSAA and perf.cpp re-defaulted it to 1). The app
  now passes "0", and the default is ON: the title's 2x/4x world pass fixes the dashed pitch lines; 50 fps with it vs ~44 without.
- **Frame skipping**: the phone had **Battery Saver on** (prime core capped 2.84 -> 1.5 GHz, GPU 525 MHz): matches ran ~45 fps and the
  uneven frames read as a stuttering ball. The app now shows a toast when Battery Saver is on. The phone's display is also set to HD+
  (1600x720); FHD+ would give the upscaler a 1920x1080 picture.
- Scene scale 1.0 was measured at ~32 fps (Battery Saver on) vs ~44 at 0.75: not worth it now that MSAA fixes the lines.

## Third freeze: second Exhibition hangs on the loading screen (2026-10-22)

The user played an Exhibition, quit it (MatchDiscontinue), started another one, and it stopped on the stadium
loading picture after `procedure: Exhibition/ExhibiFlowInit`; `LiveData/LiveDataCheck` never came. The render
loop still ran at 60 fps (56 draws a frame, `same` climbing), so it looked like a freeze but was a hang.
- simpleperf (`--sort comm,symbol`) found guest thread 11 at 66% of the samples in `sub_82417B48`: the XAPI heap's
  free-list insert, called from malloc (`831D2BF8 -> 82418F88`). Its walk of the large-block list (82417C18) never
  got back to the head.
- The process heap is at [0x84065CE4] = 0x80129000; the head of its large-block free list is at +384. Walking it
  with `dump_guest` reached node 0x8BD90008. That node's header and links were 32-bit pixels (FF272E3A ...), and
  past it was zeroed memory, which is where the walk looped.
- At the same moment the game made `MmAllocatePhysicalMemoryEx: 3600 KB -> ABCC6000`, which is physical
  0x0BCC6000-0x0C04A000. That range holds 0x0BD90000, the same bytes as the heap's virtual 0x8BD90000. The bank
  had handed out memory that a live heap segment was still using.
- Cause: the bank serves both NtAllocateVirtualMemory and MmAllocatePhysicalMemoryEx, and reuses a freed start
  first-fit. MmFreePhysicalMemory freed whatever block started at the address it was given, through any window.
  A stale physical free (PES frees these 3600 KB blocks from sub_8386CF60) could therefore release the heap's
  segment.
- Fix (memory.cpp): each free releases only what its own API allocated. Physical frees are checked against
  g_physicalLive and virtual frees against g_virtualLive. Anything else is logged as `... left alone (from X)` and
  ignored. The next run's log shows whether PES really double-frees: grep `left alone`. D3D's
  `MmFreePhysicalMemory(1, 0x500)` from 823FA00C is one such free; it never matched a block before either.
- Unverified until someone plays two Exhibitions in a row with a quit between them.
- Also fixed: `dump_guest` clamps to 4 GB. An address of FFFFFFF8 read past the guest space and killed the game.
- Verified 2026-10-22: the user played three Exhibitions in a row with no hang. The only free rejected was D3D's
  `MmFreePhysicalMemory(1, 0x500)` (823FA00C, once per match load). The 3600 KB blocks were never freed twice.
  0x500 is the likely culprit: the old code freed physical-window 0x500, and the low bank holds the runtime's own
  small blocks (thread blocks, the timestamp bundle) from its first bytes, so a live block could start there. It
  was then reused under its owner.

## OPEN (2026-10-22): heap corruption again, in Master League setup -- continue here
(Superseded by "Master League: later session status" at the end of this file; read that first.)

Repro: TopMenu, then RB to FOOTBALL LIFE, then Master League, New. Skip the intro (A). OK General Settings (A).
Nationality: Europe, Albania (A, A). Dismiss "enter the manager's details" (A). Manager's Name: A opens the Android
dialog. Type a name and tap Done; the row shows it, so the keyboard works. Then DOWN DOWN to OK and press A. The
screen stays on the stadium picture with the manager's face and never moves on.
(The user calls the confirm button "x"; it is A on this pad.)

It is the same symptom as the Exhibition hang above:
- simpleperf `--sort comm,symbol` shows guest thread 36 at 30% in `__imp__sub_82417B48` (the XAPI heap's
  free-list insert, under malloc).
- Walking the heap's large free list (head at 0x80129000+384 = 0x80129180; each node has next at +0 and prev at
  +4, with an 8-byte header before it) from `dump_guest` gave 38 good nodes. Node 39, at 0x8D8F0008, held DXT
  texture data: `00FF 9249 4924 2492 FFFF0000 00000000`. Its next pointer was FFFF0000. A safe walk loop is in
  this session's transcript: one `dump_guest <addr-8> 10` per node, stopping on any pointer below 0x80000000.
- Physical 0x0D8F0000 falls inside `MmAllocatePhysicalMemoryEx: 1024 KB align 10000 -> AD8B0000` (from
  832D2124), allocated during ML setup (game.log line ~35402 of that run). So again a physical block shares bytes
  with a live process-heap block.
- This time no `left alone` line appeared except D3D's 0x500. So the fix above (frees check their own API) did not
  cover this path. Something else gives the bank's range to two owners.

Leading suspect: in memory.cpp, NtAllocateVirtualMemory's "a commit onto an existing reservation just succeeds in
place". The XAPI heap (82418D04 reserves with type 60002000, 82418D54 commits with 60001000) commits at an address
it chooses. If that address lies outside any block the bank handed out, for example because the heap grows a
segment past its reservation or commits at its own computed base, the commit "succeeds" on memory the bank still
counts as free. A later physical allocation then lands on it.
Next steps:
1. Log every NtAllocateVirtualMemory commit at a given address, and check it with
   `kernel::FindAllocation(wanted, at, size)` that it lies inside a live block (wanted+size <= at+size). Warn
   loudly when it does not; that would confirm the cause.
2. If confirmed, make the commit allocate that exact range from the bank, or refuse it (STATUS_CONFLICTING_ADDRESSES
   / no memory) so the heap reserves a new segment.
3. Other candidates: a reserve with a non-zero wanted address (we ignore `wanted` and allocate elsewhere), and the
   far heap (`g_far`) when the bank fills.
4. Verify with the repro above, then two Exhibitions in a row with a quit between them.
The Exhibition fix (memory.cpp Release()) is built and installed and stays in.

## Master League: later session status (2026-10-22)

**Summary:** the setup flow that the section above says hangs did not hang in 9 runs of this session. I could not reproduce the
heap corruption or find the "later step" hang you reported. One 30+ s stall was seen once (below). Which screen hangs for you is
the open question; ask for it, or run `tools/explore.sh` further than I did.

### Scripts (all saved in `tools/`, all use the virtual pad, so no touch coordinates)
- `tools/to_ml.sh [stage]`: fresh launch to Master League. Stages: `menu` (main menu), `popup` (New/Load popup), `name`
  (manager's name typed), `lineup` (Choose Lineup Type popup), default `ml` (the Game Tips data-creation screen, about 95 s).
  The name is typed with `adb shell input text Tester` and the Android dialog's OK is tapped at (1142, 502).
- `tools/step.sh BUTTON [wait] [hold]`: one press, then a 640x288 screenshot in `/tmp/step.png` and the current procedure.
- `tools/explore.sh [presses] [wait] [button]`: presses repeatedly; prints procedure and busiest thread per press and writes a
  contact sheet to `/tmp/explore/sheet.png`. This is how the whole flow below was walked.
- `tools/ml_stall_hunt.sh [runs] [limit-s]`: repeats `to_ml.sh` until the data-creation screen has not reached
  `CmnReportEventCheck` after the limit, then saves a screenshot (`/tmp/stall.png`), the log (`/tmp/stall_log.txt`) and an
  8 s simpleperf recording (`/data/local/tmp/perf.data` on the phone). 6 runs: no stall, 17-19 s each.
- `tools/ml_repeat.sh`: older repeat loop; it compares against `/tmp/ml_ok_ref.png`, a temporary reference screenshot, so it
  needs one made first (screenshot of the "Choose Lineup Type" popup). Prefer `ml_stall_hunt.sh`.

### Route verified (procedure names in brackets)
TopMenu -> RB x3 (Football Life) -> RIGHT -> A (Master League) -> New -> intro cutscene, A to skip -> General Settings OK ->
nationality notice, Europe, Albania -> "enter the manager's details" -> Manager Settings: name via Android dialog, DOWN DOWN to
OK -> Choose Lineup Type -> Club Team Lineup -> "choose the club" notice -> Arsenal -> Coop Match Settings OK -> Game Tips
(`CmnModeDataCreation`, `CmnUpdateDayBegin`; 17-19 s) -> Club Secretary reports (`CmnReportEventCheck`, `CmnUpdateDayEnd`,
`CmnGrowthCheck`, `CmnFinanceReportCheck`, `CmnStaffReportCheck`) -> Master League main menu (`CmnMainMenuSelector`) ->
Starting Lineup with KICK-OFF -> the Master League match loads and plays (45-57 fps, no heap break).
The pause menu's last tile is "Top Menu"; it asks "Return to Top Menu? Unsaved data will be lost." (Not tried.)

### Suspect ruled out
The leading suspect above (a commit onto an existing reservation that succeeds in place, outside any live block) does not
happen: `NtAllocateVirtualMemory` now warns `COMMIT of ... is outside any live block` and `RESERVE asked for ... address
ignored`; neither line appeared in any run. The XAPI heap commits at 0x80129000+ and 0x80149000/0x80150000, all inside its
1 MB block at 0x80129000. The warnings stay in (capped at 40 lines).

### New diagnostics (polled every 300 ms from `runtime/gpu/debug_watch.cpp`; create the file on the phone)
- `touch files/check_heap`: one walk of the XAPI process heap's large-block free list (`kernel::CheckProcessHeap`). Logs
  `heapcheck: ... intact, N large nodes`, or `BROKEN` with the node, its words and `kernel::OwnersOf` (every live virtual or
  physical block covering those bank bytes, with the guest call chain that allocated it).
- `files/heap_watch` (kept): the same walk on every poll, logging each distinct break once and `intact again`. It walks
  without the game's locks, so one transient `BROKEN` can be a race with the allocator; trust a break that `check_heap`
  confirms a moment later. Both files currently exist on the phone (`adb shell rm` them to stop).
- `files/alloc_watch` (kept): every 2 s `alloc: N allocs/s, scan X ms, zeroing Y ms for Z MB, lock waits, free blocks, write
  faults/s` (`kernel::ReportAllocRate`). In the passing runs the allocator was idle (0-100 allocs/s).

### The one stall seen (not reproduced in 9 later runs)
On the Game Tips screen for 30+ s after `CmnUpdateDayBegin`, with the heap intact (`check_heap` ok):
- guest thread 35: 79% kernel plus `NtYieldExecution`/`sched_yield`, a spin-wait.
- guest thread 36: 60% kernel and 45% under `art::SignalChain::Handler` (a fault storm), all under `kernel::AllocateGuest`.
  `Heap::Alloc` zeroes a reused block with `memset` while holding the heap lock, and pages the GPU watch has made read-only
  fault on each first write. No single zeroing took 100 ms (no `memory: zeroing` warning).
- Hypothesis, unverified: a burst of faulting memsets under the heap lock while another thread spins on malloc's critical
  section. If it recurs, `tools/ml_stall_hunt.sh` captures what is needed, and the `alloc:` line shows `write faults/s`.

### Not tried (candidates for "the later step")
- Quit to the top menu and start a second Master League in the same process (the Exhibition hang was a second load).
- Finish a Master League match and go through the post-match screens, then the next match day.
- The other Master League menus (Team Management, Transfers, Database, System), and saving.

### State of the phone and build
`tools/deploy.sh` has installed the build with all of the above; the Android default is scene scale 0.75, FSR upscaler and
MSAA as described in the earlier sections. `kCacheVersion` is 11.

## Master League: menu pictures vanish after Advanced Search -- missed function 82B29428 (2026-10-22)

User route: ML main menu, Team Management, Negotiations, Advanced Search (Club Teams = London FC), Search, scroll the
players, B. Back in Negotiations the tiles' pictures (My Team, Other Clubs, Scouting ...) were blank white, and the
Tex counter fell from 237 MB to 162 MB. Reproduced with the virtual pad: `tools/pad.sh tap 0 UP` (wraps to the Search
button), `tools/step.sh A`, DOWN x8, B, B.
- game.log had 84 `indirect call to 82B29428 has no recompiled function` reports, all from lr 82BECE5C (r3 -> object with
  vtable 820A7CD8, r4 = 0, r9 = the target). They began when the results screen opened and repeated on leaving it.
- 82B29428 is a function start (`mr r11,r3; li r3,0; cmplwi r4,15 ...`, preceded by `blr` at 82B29424) that PES.toml
  swallowed into `{ 0x82B29390, 0x2EC }`: the vtable-only case from "Second freeze cause" above. Fix: split it into
  `{ 0x82B29390, 0x98 }` + `{ 0x82B29428, 0x254 }`. Regenerated with `RECOMPILE_ONLY=1 GAME=../GAME ./build.sh`, then a
  full ninja build and deploy. Unverified until the route above is replayed on the new build.
- Not new and not investigated: 129 `indirect call to 00000000` reports from lr 83105304 since boot (null callbacks).
  The reporter returns, and the game carries on.
- A broader sweep would help: every vtable slot pointing at an address that is inside a function's bound but is not a
  start. tools/fixbounds.py's strict vtable rule found some; this one slipped through because its neighbours in the
  vtable are not all code pointers. Run `tools/find_missed_switches.py`-style scan over `.rdata` pointers.

## Master League setup stall: write-watch livelock, FIXED (2026-10-22)

The stall the other session saw once ("Game Tips for 30+ s", thread 36/35 in a memset, 45% in `art::SignalChain::Handler`)
and that reproduced in 3 of 5 setup runs here (also later at CmnReportEventCheck with the screen black and 0 FPS).
- Not the `heap_watch`/`alloc_watch` debug files (removed, the stall stayed). Not a large allocation.
- simpleperf on the busy guest thread: `NtAllocateVirtualMemory -> kernel::AllocateGuest -> memset`, 98% in memset, half of that in
  the signal handler. The detector added to `gpu::watch::HandleFault` (same thread, same page 1000 times in a row) logged:
  `write watch: page 14297 (guest ADF64000) faulted 1000 times in a row on one thread, state 1`. State 1 is kLoose: writable.
  The page was read-only. The record and the real protection disagreed, and the handler returned "handled" without changing
  anything, so the memset's write faulted for ever.
- Race (memory_watch.cpp): `Arm` stores kArming on a run of pages, THEN protects them read-only. A writer's `Loosen` (from a fault
  on a page that was Watched) can run in between: its CAS to kLoose succeeds, then `Arm`'s protect lands on top. The page is
  read-only and recorded Loose; `Loosen` returned at once for kLoose.
- Fix: `Loosen` makes the page writable even when the record says loose; `Arm`, when its final CAS to kWatched fails and the page
  reads Loose, makes it writable. The 1000-faults detector stays as a safety net and logs `made writable by force` if it ever fires.
- Unverified by a long soak. If `made writable by force` shows in a log, the race has another form.
- The same race could have caused other "game sits in a memset/loop" reports; the Exhibition hang's cause was a different bug (the
  physical free), already fixed above.

Still open (this session's other thread): Negotiations tile pictures blank after the player list. Findings so far: not texture-cache
staleness on this phone (shadow and write watch are off for the texture cache path here, signatures are full hashes, rechecked
every 16 frames); not a failed read (new log `textures: could not read` never fired; failed reads now retry after 30 frames);
the stadium behind the menus is a 320x180 resolve (04D30000/04D6C000, three a frame) and the tiles' pictures are other 320x180
resolves (08AD0000/08B0C000) of source photos. `resolve320:` log lines record the first resolve of each run of frames.
My Team and back, or any other re-entry, restores them. The fix above may or may not touch it; retest.

## Negotiations tile pictures blank after Youth Team (long scroll) -- FIXED, 2026-10-22

Repro (user): Master League, Team Management, Negotiations, Youth Team, scroll far down (every player), B. The six tile
pictures came back white. Advanced Search + scroll did the same; My Team and back, or re-entering the screen, restored them.
- A frame dump of the blank state against a good one (`touch files/dump_frame`, then `frame_images/*.pnm` and the `DUMP tex` lines)
  differed in one texture: the 984x480 tile atlas. Good: read from guest memory 0DCA0000. Bad: fetched at 0DBA0000 and bound as a
  "resolve copy" of that address -- the GPU image of the Youth Team player-portrait render target (1024x1024, a grey face).
- The title reuses freed memory (first-fit): after the portraits are done it loads the tile atlas into the range the portrait
  render target resolved to. renderer_draw.cpp's rule for when a fetch reads a resolve copy only compared format and size (984x480
  fits inside 1024x1024, both 8_8_8_8), so the stale copy won.
- Fix: at each resolve (renderer_resolve.cpp) the destination's guest memory is sampled (256 words, `SampleGuestMemory`) into
  `Resolved::memorySignature`; a fetch (renderer_draw.cpp) reads memory instead of the copy when the sample has changed. A resolve
  does not write guest memory, so a change means the title wrote there. It costs about 256 loads per resolve and per resolve fetch.
  This phone has no write watch (NO_SHADOW), so a sample is what there is; a rewrite that leaves all 256 words unchanged is missed.
- Verified with three long scroll passes: tiles intact. The log shows `renderer: <addr> was resolved to, then written by the title`
  for two other addresses: 0EFF0000 (708x148 fmt 6) and 0F520000 (512x128 fmt 20). Those are likely the same bug in other places, and
  the user's other report -- player OVR numbers sometimes not loaded properly while scrolling the youth players -- could be it. In
  the two screenshots after the fix the list's ratings were right, but the bug is intermittent, so it is not shown fixed.
- Leftovers from the hunt, all harmless: `textures: could not read ...` log (and failed reads retry after 30 frames), `resolve320:`
  log lines (first resolve of each run of frames, cap 1500), `still empty at submit` cap raised to 200, a log for large stack
  requests and for zeroing >= 8 MB. Remove them when done.

## Open: some Master League news photos are blurred (2026-10-22)

User report: the picture in the Master League news (Forward Time tab) is blurry for some stories (K. Gibbs "I'm Focused on my Football", A. Sanchez
"Maestro", the "Looking Forward to the Match" player); others are sharp (Tester appointed, M. Neuer, the logos). Seen before today's fixes too, so not
a regression of them.
- Not the display path: the picture's source, a 960x540 render resolved to 0ECC0000 and sampled as a 1280x720 copy, is already blurred in the dumped
  frame_images (the whole subject, not only the background). The kit and face textures it is built from (0EC10000, 0E030000) are sharp.
- The photo is rendered once, when the main menu loads, not per frame: dump_frame in later frames shows no 960x540 resolve. Ten dumps while forwarding
  time missed it (a dump is armed for one frame and takes about 2 s). Catching it needs a dump armed to the frame of that render, e.g. a poll flag
  that arms dump_frame when a resolve to a 960x540 surface is first seen and keeps the next N frames.
- Suspects, none tested: (1) the depth-of-field's depth input, since a subject-wide blur means the "in focus" mask came out empty (the
  handoff says the oDepth export is "translated but unverified"; the log also warns `a pass pairs a 640x360 colour surface at scale 1.00 with a
  1280x720 depth surface at 0.75`); (2) the scene scale 0.75 (MW2_SCENE_SCALE, applies to surfaces 1152+ wide only, so probably not).
- A/B in progress: files/scene_scale holds 1.0 on the phone (the build otherwise defaults to 0.75). `rm` it to go back. The game was restarted with it.

- Result (user, 2026-10-22): at scene scale 1.0 the blurred news photos look right ("I think its resolved"). So the cause is the 0.75 scene scale, not
  the depth export. The photo's render pass mixes surfaces at different scales (the `a pass pairs a ... colour surface at scale 1.00 with a 1280x720
  depth surface at 0.75` warning), which is the likely route to a wrong depth-of-field mask. Fix options: keep 1.0 in menus and use 0.75 only in a
  match (the match is GPU-bound at 1.0), or make `SceneScaleFor` (renderer_state.h) scale colour and depth surfaces of a pass together. Until then
  `files/scene_scale` = 1.0 is on the phone; remove it for the 0.75 default.
