# Handover: launcher, controller macros, capture, performance and the crowd (22 October 2026)

Written at the end of one long Claude Code session. Everything described here is already committed in this repository
(`git log`: `ac6abf7` .. `ffbd9ad`), except one open experiment noted under "Open". The earlier port history is in
[HANDOFF.md](HANDOFF.md) and [PORTING.md](PORTING.md); this file covers what was added after it.

The phone is a Galaxy S20 FE (SM-G780G, Adreno 650, Android 13), serial `RR8RB04X2SV`, rooted with Magisk. The package is
`com.pes2017.recomp`. Game files are on the phone in `/sdcard/Android/data/com.pes2017.recomp/files/game/`.

---

## 1. What was done

### 1.1 The Android launcher was rebuilt for PES 2017

The launcher was an MW2 one. It is now a PES one. Files are under `android/app/src/main/`.

| Change | Where |
|---|---|
| Main menu: KICK OFF, SELECT GAME FOLDER, install from disc image, SETTINGS, graphics driver, log, updates, quit. Navy and cyan theme, PES wordmark. | `res/layout/activity_main.xml`, `res/values/strings.xml`, `themes.xml`, `BackdropView.kt`, `MainActivity.kt` |
| **Select Game Folder.** System folder picker, then a storage-permission prompt (All files access on Android 11+, the normal permission before) only if the folder is outside the app. Runs the game in place, no 6 GB copy. A copy into the app is the fallback. | `GameFolder.kt`, `MainActivity.kt`, `InstallActivity.kt` |
| **Auto-detect the game first**: chosen folder, then the app's own storage, then common folders (only those readable). The user is asked only if nothing is found. | `GameFolder.autoDetect`, `MainActivity.refresh` |
| MW2-only menus removed (other-app launch, mods, TU6/TU0, split-screen warning, network tab, cheats, FOV, look sliders). | deleted `Cheats.kt`, `MpCheatsData.kt`; edits across the Kotlin |
| **PES settings** in four tabs (Picture, Performance, Controls, Game files): scene render quality (`PES17_SCENE_SCALE`), FSR upscaler and sharpness, 30 fps cap, low-memory mode (`PES17_NO_SHADOW`), texture memory, compile-all-shaders, storage-access status, forget folder, clear caches and logs. | `SettingsActivity.kt`, `Prefs.kt`, `activity_settings.xml`, `GameActivity.applyOptions` |
| **Football touch overlay**: A PASS/SWITCH, B SHOOT/SLIDE, X LOB/PRESS, Y THROUGH/MATE, RB SPRINT, RT PLAYER RUN, LB PACE, LT SKILL, sticks MOVE and SKILL, D-pad TACTICS. The camera-look area and shooter labels are gone. Captions are my recollection of the Xbox default layout and are all in `ControlLayout.defaults()`. | `ControlLayout.kt`, `TouchOverlayView.kt` |
| Launcher icon: the PES 2017 cover art, adaptive plus legacy PNGs. The art is Konami's; releasing it publicly is the owner's decision. | `res/drawable/ic_launcher_foreground.xml`, `drawable-nodpi/ic_launcher_art.png`, `mipmap-*` |
| Update check disabled until this port has its own release page. It used to point at another project's GitHub repo. | `MainActivity.kt` (`RELEASES_API`, `RELEASES_PAGE` are empty) |
| All remaining MW2 names in the Android sources, the unused `config/MW2*.toml`, and the `_mw2_specific/` sources (archived to `../_mw2_specific.tar.gz`, one level above the repo). | repo-wide |

### 1.2 Controller macros and the capture button

**Macros** (`Macro.kt`): record what a *physical* controller does, play it back, with timing. A macro is a text file
`files/macros/<name>.macro`, one line per state change: `ms slot buttons lt rt lx ly rx ry`. The pause menu has "Record
controller macro" (asks for a name on stop) and "Play macro". Touch input is not recorded.

**Remote control over adb**, so tests need no taps or screenshots. Opt in by creating `files/macros/.remote_control` on the phone, then:

```bash
adb shell am broadcast -a com.pes2017.recomp.MACRO -p com.pes2017.recomp --es cmd play --es name play
# cmd: record | stop | play | stopplay | list | capture_start | capture_stop   (--es name X, --es note "..." (no spaces over adb), --ei loops N)
```

The user's macro **`play`** goes from the title screen to a match: start playback after the `PreStartup` procedure (+3 s); the match
setup comes about 29 s later. Always use it for in-match tests (see the memory notes below).

**CAPTURE button** (`CaptureSession.kt`): the first press starts, the second stops and asks for a name and a note. It saves
`files/captures/<date>-<name>/` with `summary.txt` (device, build, renderer, driver, every setting, fps and worst frame), `stats.csv`
(fps, frame time, texture memory, battery temperature, thermal state, free RAM every 0.5 s), `game.log` (the run's log plus the
400 lines before), `logcat.txt`, `screenshot.png`, and the controller macro of the stretch. Pull it with `adb pull`.

### 1.3 The game did not boot after the rename (fixed)

The generated, git-ignored header `ppc/ppc_recomp_shared.h` still used the old `MW2_TRACE_INDIRECT` / `MW2ReportBadIndirectCall` names,
so an unrecompiled call jumped to address 0 and the game died a second after kick-off. Renamed in the header (a full rebuild, about
25 minutes, was needed). **If `build.sh` regenerates `ppc/`, check that header has the `PES17_` names.**

### 1.4 Performance work (details in [performance.md](performance.md))

- **The limit in a match is heat.** At skin 47–48 °C (Android thermal status CRITICAL) the GPU is held to 305–400 MHz and the big
  cores to about 1.5 GHz. Identical runs swing 42–60 fps. A cool phone ran 57–60.
- Added: throttled pipeline and shader cache writes (they were every 5 pipelines, on the draw thread and under the pipeline-build lock;
  the start of a cutscene froze for about 5 s). GPU pass timing (`files/gpu_timing`). A yield back-off for the guest's spin waits
  (`runtime/kernel/yield_backoff.h`, `files/yield_tuning`): saves CPU, costs fps, **off by default**. Small render passes
  (`files/small_passes`): saves GPU pass time, no measurable fps, **off by default** (it clipped the crowd).
- Not solved: a steady 60 fps in a match. The remaining levers are less shading work, a cooler phone, or sizing the large
  960x1536 colour+depth passes better.

### 1.5 The crowd (details in [PORTING.md](PORTING.md), "Crowd, second pass")

The crowd was invisible, then black silhouettes, and is now coloured. Three causes, all fixed:

1. **The shader translator skipped `kill_*` instructions** whose result is written nowhere (`kill_gt _, ...`), so no sprite
   background was ever discarded. Fix: `TranslateAlu` always builds kill opcodes (`shader_translator.cpp`). Affects every shader that discards.
2. **A depth-only clear wiped the stencil**, which PES uses to mark crowd pixels two passes before it tests them. The clear had
   the stencil test off, which leaves stencil alone on the console. Fix: `ClearAliasedDepth` clears stencil only when the clear
   writes it (stencil on, REPLACE, full write mask).
3. **The crowd's colour atlas was never filled**: the title draws 256x2048 swatches, resolves them, and packs the memory into the
   DXT1 atlas on the CPU. Our write-back of resolves to guest memory stopped at 1024 on a side. Fix: area limit (about 1M pixels,
   2048 per side) in `renderer_resolve.cpp`.

---

## 2. Open

1. **Half-time stats board shows the crowd through its text** (user capture `20261022-205611-score`). Cause found: after fix 2 the
   crowd's stencil marks (0x10) persist in the 1x depth image, and the interface's sprites test stencil EQUAL 1, so they fail wherever
   crowd was behind them. The interface clears through a 4x depth image at the same tile, which does not clear the 1x one (on the
   console it is one EDRAM buffer). Attempted fix: `ClearAliasedStencil` (`renderer_targets.cpp`, called from `renderer_draw.cpp`)
   clears the stencil of other-sample depth images at the same tile. A dump showed it firing (`stencil of the 4x depth image ...
   cleared`), but **I had not yet re-checked the stencil before the interface draws, nor the half-time screen itself.**
   Next: run `tools/aerial_dump.sh <dir> 40`, look at the `DUMP   stencil before draw` lines for ps `B401ACD7...`: they must show no `10:`
   or `11:` values. Then reproduce half time (the clock is slow: about 10 minutes of play) and screenshot the board.
2. **"Does the crowd cost frame time?"** (asked last). Not measured. The crowd was already drawn before the fix; added work is small.
   To measure: `play` macro, GPU pass time with and without the crowd draws (`files/skip_ps` with `B4BBEAC4E75DDB31`,
   `70F64A42C2C649AA`, `4934EC0F7DD0AAB6`).
3. Temporary diagnostics are still in the code (they only run in a dump frame or when a file exists on the phone): stencil dump,
   `at_<addr>` resolve dump, `tex_*` dump, `crowd_hunt`. Safe to leave; remove when done.
4. The touch-overlay captions for LB, LT and RT, and the pass/shoot layout, are from memory and unverified on a real game.
5. `config/PES.active.toml` shows as modified in git; that is not from this session.

---

## 3. How to build, install and test (what actually worked)

```bash
# native library (about 1 min for a runtime-only change; 25+ min if ppc/ headers change)
cd pes2017-android && export PYENV_VERSION=3.10.14 ANDROID_HOME=$HOME/Library/Android/sdk
ninja -C build-android -j"$(getconf _NPROCESSORS_ONLN)" pes17
# package the libraries and the apk, install
NDK=$ANDROID_HOME/ndk/28.2.13676358; BIN=$NDK/toolchains/llvm/prebuilt/darwin-x86_64/bin
STAGE=$PWD/build-android/stage/arm64-v8a
cp build-android/libpes17.so $STAGE/ && $BIN/llvm-strip --strip-debug $STAGE/libpes17.so
(cd android && sh ./gradlew --no-daemon -q :app:assembleRelease -PprebuiltNative=$PWD/../build-android/stage)
adb install -r android/app/build/outputs/apk/release/app-release.apk
```

- Kotlin-only check: `cd android && sh ./gradlew :app:compileDebugKotlin -PprebuiltNative=/tmp/none --offline -q`
- `build-android` was re-configured once for the renamed `pes17` target (`cmake -S . -B build-android -G Ninja -DCMAKE_TOOLCHAIN_FILE=... -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-26 ...`, same flags as `build.sh`).
- The test scripts (new, in `tools/`): `run_macro.sh "<sleep us> <free yields>" [macro]` (fps, CPU cycles, skin temperature),
  `aerial_dump.sh <dir> [extra s]` (screenshot, frame dump, logs), `crowd_dump.sh <dir>` (dumps until a frame has the crowd draws).
  They `pull` frame images from `files/frame_images/`.
- The frame dump: `adb shell touch .../files/dump_frame`. `tools/xenos_disasm.py` disassembles the `DUMP ucode` lines.
- Quirks that cost time: macOS `sed -i` needs `''`; `adb shell am broadcast --es note "two words"` splits at the space; the phone's
  active user is not 0 for `pm list`; the first match after an install is slower while shader caches warm up (never compare the first run);
  `rm -rf $VAR/*` is blocked by the safety check, use a fresh directory.

## 4. Files on the phone worth knowing

`files/`: `game/` (the files), `game.log`, `launcher.log`, `shader_cache.bin`, `macros/` (`play`, `playmatch`, `smoke`, `inmatch*`, `.remote_control`),
`captures/`, `frame_images/` (dump output), `saves/`. Switch files (create or delete, most are polled at once): `gpu_timing`, `small_passes`,
`no_writeback_cap`, `skip_ps` (hex hashes), `draw_range` ("lo hi"), `scene_scale`, `no_msaa`, `yield_tuning` ("us spins"), `crowd_hunt`,
`dump_frame`, `capture_request`.

---

## 5. The memory notes (Claude Code's own, `~/.claude/projects/-Users-macdzky-Development-playground-PES2017-RECOMP-pes2017-android/memory/`)

These are working notes that a later Claude Code session loads automatically. They are not in the repository.

| File | What it holds |
|---|---|
| `MEMORY.md` | The index: one line per note. |
| `feedback_use_play_macro.md` | **For any in-match test on the phone, replay the user's `play` macro; do not use `tools/to_match.sh`** (adb taps). How: relaunch, wait for `PreStartup` (+3 s), broadcast `play`, measure about 30 s after `Match/MatchSetup`; run settings alternately because identical runs vary ±5 fps with heat. |
| `perf-findings-pes2017.md` | Heat is the main limit (CRITICAL thermal status, GPU 305–400 MHz). What was tried with no fps gain (yield back-off, small passes) and what to try next (size the 960x1536 passes from the clear rectangle's viewport, check the picture with a CAPTURE screenshot). Build loop. |
| `bc-astc-prototype.md` | Written by **another session** the same day: stock Adreno 650 has no BC; `PES17_BC_ASTC=1` transcodes BC1/BC2/BC3 to ASTC 4x4 (texture memory 433 MB to 108 MB, fps within noise, off by default; commits `58ba347`). Open: more checking of match visuals. |

Two of these should be updated when the open items above are settled: the perf note (the crowd and the small-pass finding) and a new note
for the crowd (the three causes and the stencil board bug), if you want them to survive into future sessions.

## 6. Where to look first next time

- `docs/PORTING.md` section "Crowd, second pass" and `docs/performance.md` for the findings in detail.
- `git log --stat ac6abf7..HEAD` for every file touched.
- `Macro.kt`, `CaptureSession.kt`, `GameFolder.kt` for the new Android pieces; `renderer_targets.cpp` (`ClearAliasedDepth`, `ClearAliasedStencil`),
  `renderer_resolve.cpp` (the write-back condition), `shader_translator.cpp` (`TranslateAlu`) for the renderer fixes.
