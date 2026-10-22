# Building from source

The retail Modern Warfare 2 disc's executables, as title update 6 patches them,
are converted to C++ with
[XenonRecomp](https://github.com/hedge-dev/XenonRecomp), compiled as native
x86-64, and linked with a host runtime that stands in for the console's kernel,
GPU (through Vulkan) and audio hardware ([runtime.md](runtime.md)).

The game data, the generated C++ and the XenonRecomp checkout are gitignored.
Everything under version control is hand-written or a patch.

For a phone, see [android.md](android.md): the steps below are done first on
a desktop (the recompiler runs there), and Gradle then builds the same
`CMakeLists.txt` for arm64.

## Requirements

- `cmake`, `ninja-build`, `clang-18`, `lld-18`, `python3`, `git`.
- The Vulkan headers and loader (`libvulkan-dev`). Without them the runtime
  builds with no window.
- SDL3 and Dear ImGui are fetched; SDL3 is linked statically; on Linux it needs the usual
  development packages for its video, audio and input backends (X11, Wayland,
  ALSA/PulseAudio/PipeWire, udev, dbus). `.github/workflows/release.yml` lists
  them.
- The retail ISO, or at least `pes17/tu0/default.xex` and
  `pes17/tu0/default_mp.xex`.
- Title update 6: its package, or its files in `pes17/update/`
  ([Title update 6](#title-update-6)).

## build.sh

`./build.sh` does everything, in order:

1. clones XenonRecomp at a pinned commit and applies
   `patches/xenonrecomp-pes17.patch` (an existing `XenonRecomp/` is reused as it
   is);
2. builds XenonRecomp and XenonAnalyse;
3. extracts `default.xex` and `default_mp.xex` from the ISO into `pes17/tu0/`,
   and every `.ff`, `.pak` and `.bik` into `pes17/game/` (files already there
   are kept); then applies the title update, which writes the executables the
   rest works on, `pes17/default.xex` and `pes17/default_mp.xex`
   ([Title update 6](#title-update-6));
4. writes the flat PE image (`pes17/default.pe` or `pes17/default_mp.pe`) with
   `tools/xexdump.py`;
5. finds jump tables with XenonAnalyse (`config/pes17_switch_tables.toml`,
   `config/pes17mp_switch_tables.toml`);
6. recompiles into `ppc/` or `ppc_mp/`;
7. generates `ppc_recomp_shared.h` and the kernel import stubs
   (`tools/genshared.py`, `tools/gen_kernel_stubs.py`);
8. configures and builds the runtime and the launcher with CMake.

| variable | effect |
|---|---|
| `TITLE=sp\|mp` | `sp` (default): `default.xex`, the campaign and special ops. `mp`: `default_mp.xex`, the multiplayer. Each has its own recompiled tree, switch tables, recompiler config and build directory |
| `TU=<path>` | the title update: its package, or a folder holding its files. Needed until `pes17/update/` has them |
| `VERSION=tu0` | builds the disc's own executables, without the update; see [The disc version](#the-disc-version) |
| `RELEASE=1` | builds without diagnostics (`-DPES17_DIAGNOSTICS=OFF`) and, on Linux, with the C++ runtime linked statically (`PES17_PORTABLE`); adds `-release` to the build directory |
| `ONLINE=none\|lan\|steam` | the online service ([multiplayer.md](multiplayer.md)); `none` (default) keeps system link on this machine; `steam` has lan behind it |
| `WINDOWS=1` | cross-compiles for Windows with llvm-mingw; the build directory becomes `build-win...` and the executable `pes17.exe` |
| `LLVM_MINGW=<dir>` | the unpacked [llvm-mingw](https://github.com/mstorsjo/llvm-mingw) release, required by `WINDOWS=1` |
| `ISO=<path>` | the disc image. Without one, `pes17/tu0/default.xex` and `pes17/tu0/default_mp.xex` are enough to build, and no game data is extracted |
| `BUILD_DIR=<dir>` | builds there instead of the default directory |
| `REGENERATE=0` | keeps the recompiled tree already there (skips steps 5-7), for a second build of the same title, e.g. with another `ONLINE` |
| `CMAKE_EXTRA` | passed to the configure step (a compiler launcher, `FETCHCONTENT_BASE_DIR`, ...) |

Build directories:

| | campaign | multiplayer |
|---|---|---|
| diagnostic | `build/` | `build-mp/` |
| `RELEASE=1` | `build-release/` | `build-mp-release/` |
| `WINDOWS=1` | `build-win/`, `build-win-release/` | `build-win-mp/`, `build-win-mp-release/` |

A second build directory reuses the SDL3 and FFmpeg sources `build/` fetched.

### Title update 6

The update is a package holding a patch for each executable (`default.xexp`,
`default_mp.xexp`) and three fastfiles for the multiplayer (`patch_mp.ff`,
`dlc1_ui_mp.ff`, `dlc2_ui_mp.ff`). After extracting the disc's executables,
`build.sh`:

- unpacks the package (`tools/stfs.py`) into `pes17/update/`, or copies the
  files from the folder `TU` names;
- applies each patch to the disc's executable with XenonRecomp's own patcher
  (`tools/xexpatch.cpp`, built against its library), writing `pes17/default.xex`
  and `pes17/default_mp.xex`;
- copies the three fastfiles into `pes17/game/`.

The update changes one of the campaign's 11,133 functions, and about 260 of the
multiplayer's 11,579 with about 270 added; nearly every multiplayer function
sits at another address than on the disc. The kernel imports are the same.

A player gets the same thing from the launcher, which applies the update to
the disc's executables at install time ([The launcher](#the-launcher)).

### The disc version

`VERSION=tu0` builds the disc's executables as they are. Everything of theirs
carries the version: the image and a game folder in `pes17/tu0/`, the configs
`config/MW2.tu0.toml` and `config/MW2MP.tu0.toml`, the trees `ppc_tu0/` and
`ppc_mp_tu0/`, and `-tu0` on the build directory. The build defines
`PES17_VERSION_TU0`, which selects the disc's blocks in `runtime/title.h`.

    VERSION=tu0 TITLE=mp ./build.sh
    ./build-mp-tu0/pes17 pes17/tu0/default_mp.pe pes17/tu0/game

`pes17/tu0/game/` links to everything in `pes17/game/` but the update's fastfiles:
the disc's multiplayer would load a `patch_mp.ff` it found. The installer
works with this version, which is the one a player can install.

The two versions' configs and blocks in `title.h` hold the same functions,
found in the other executable by their instructions with the address-bearing
fields masked out, and the same data, found by what the same instructions of a
matched function form. The multiplayer's client state is 0x200 larger in the
update; the fields the runtime reads kept their offsets.

## Running

A player's copy is the launcher and the two game executables in one folder,
with the game installed into `game/` beside them. A game executable started
with no arguments loads the installed title, or starts the launcher when there
is none ([runtime.md](runtime.md#loading-the-image)).
A development run names the image and the game folder:

    ./build/pes17 pes17/default.pe pes17/game
    ./build-mp/pes17 pes17/default_mp.pe pes17/game

The multiplayer hosts a system-link match to reach a map:

    PES17_NET_LINK=1 PES17_CONSOLE="8:map mp_afghan" ./build-mp/pes17 pes17/default_mp.pe pes17/game

The switches are in [switches.md](switches.md).

## CMake options

| option | default | effect |
|---|---|---|
| `PES17_TITLE` | `sp` | which executable: `sp` or `mp` (defines `PES17_TITLE_MP`, selecting the addresses in `runtime/title.h`) |
| `PES17_VERSION` | `tu6` | which version of it: `tu6`, or `tu0` for the disc's (defines `PES17_VERSION_TU0`) |
| `PES17_DIAGNOSTICS` | `ON` | traces, dumps, statistics, end-of-run reports, the stutter detector and pacing timeline, the flash hunt, the write watchpoint and the headless harness (walker, input script, run deadlines, watchdog); see `runtime/diagnostics.h`. `OFF` unsets every diagnostic switch whatever the environment says |
| `PES17_LOGGING` | `ON` | `OFF` compiles out every log line, warnings included |
| `PES17_TRACE_INDIRECT` | `ON` | the generated code checks an indirect call's target and reports a missing one instead of jumping to null |
| `PES17_ONLINE` | `none` | the online service: `none`, `lan`, or `steam` (Steam, then lan) |
| `PES17_PORTABLE` | `OFF` | links libstdc++ and libgcc statically (Linux) |
| `PES17_USE_SDL` | `ON` | SDL3 for the window, input and audio |

CMake reads the SHA-256 of the executables in `pes17/` and `pes17/tu0/` and of the
update's fastfiles in `pes17/update/` at configure time: a game executable runs
only the title executable it was recompiled from, and the launcher installs
only that disc and that update.

## The launcher

`pes17-launcher` (`launcher/`) is built with every build directory, beside
`pes17`. It is one executable: Dear ImGui (fetched, like SDL3) on SDL's own
renderer, three fonts from `third_party/fonts/` written out as arrays at
configure time, and XenonRecomp's patcher compiled in from its checkout with
the LZX decoder and AES it uses.

Its icon is in `launcher/icon/`: `launcher.ico` is linked into the Windows
program as a resource, and `launcher.bmp` is written out as an array like the
fonts and given to the window on both systems. `tools/launcher_icon.py` makes
the two from the campaign's icon in the PC game's `iw4sp.exe`: the left half as
it is, the right half in the multiplayer's colours.

| file | what |
|---|---|
| `main.cpp` | the window's loop, what each entry does, the file dialog and dropped files, and the terminal mode |
| `ui.cpp` | the one screen, drawn by hand: a computed backdrop whose smoke drifts, the column of entries, the pane, the wordmark |
| `setup.cpp` | the install: checks the disc, gets the update, patches the executables, copies the files |
| `disc.cpp` | reads a disc image (XDVDFS) or an extracted folder |
| `package.cpp` | reads the update's package (STFS), as `tools/stfs.py` does |
| `download.cpp` | one file over HTTPS: `URLDownloadToFile` on Windows, the `curl` program elsewhere |
| `update.cpp` | looks for a newer release and puts it in place of the running programs |
| `report.cpp` | a bug report: a run with its log kept, the system's description, the new-issue page |
| `settings.cpp` | what the player sets for the game, kept in `.env`, which the game reads as it starts |
| `sound.cpp` | the game's two menu sounds, read out of the installed `code_post_gfx.ff` at each start and played as the entries are moved through and chosen; none without an install |
| `profile.cpp` | the profile screen's changes to the files under `saves/` ([saves.md](saves.md#what-the-launcher-changes)) |
| `playerdata_layout.h` | generated: where the multiplayer's stats file keeps what `profile.cpp` changes |

An install, in order: the disc's two executables are read and checked against
the known disc; the update is taken from the file or folder given, from a
package left beside the launcher, or downloaded from CoD Xenon's archive of
title updates (`codxenon/xbox360-title-updates`) at a pinned commit; its three fastfiles are checked, and each patch is applied in
memory and the result checked against the executable the build was made from.
Only then are the disc's `.ff`, `.pak` and `.bik` copied into `game/` (a file
already there, whole, is kept, so an install cut short resumes), then the
update's fastfiles, and the two patched executables last: both present and the
right ones is what a finished install is. With the disc's executables already
in `game/` (an install made by the disc version), only the update is applied
and no disc is asked for. A `VERSION=tu0` build installs the disc as it is.

    pes17-launcher --install [<disc image or folder>] [--update <package or folder>]

does the same from a terminal; with no disc it updates the install in place.

The screen is a description (`ui::Frame`) that `main.cpp` fills each frame from
a list of entries, each with an action and the text the pane shows for it.
PROFILES, GRAPHICS and REPORT A BUG swap the list for their own (`ProfileEntries`, `GraphicsEntries`,
`ReportEntries`); MAPS is an entry without an action yet. An entry with a range (FOV) sets
`ui::Frame::slider`, and the pane draws a track for it; FOV's also shows a street drawn at the
angle (`preview.cpp`), with the game's projection, to say what the number does before the game
is started.
PLAY CAMPAIGN and PLAY MULTIPLAYER start `pes17-sp` and `pes17-mp` beside the
launcher, the names a release gives the two game executables.

### Updating itself

CHECK FOR UPDATES (`update.cpp`) looks only when the player asks. It fetches
GitHub's description of the newest published release
(`api.github.com/repos/.../releases/latest`), which has the release's tag and,
for each archive, its name, size, SHA-256 and address, and compares the tag
with its own. The workflow gives the build its tag
(`RELEASE_TAG=v0.3.0 ./build.sh`, CMake's `PES17_RELEASE_TAG`); a build without
one has nothing to compare and the entry is off. The archive it wants is the
one for its system and online service, `pes17-<tag>-<linux|windows>-<service>`.

Choosing UPDATE TO downloads that archive into `update/` beside the launcher,
checks its SHA-256, unpacks it with the system's `tar` (Windows 10 and later
have one, and it reads a `.zip`), and swaps each file in: the one it replaces
is moved to `update/old/` first, and moved back if a later one fails. A
running program can be moved but not deleted, the launcher included, so
`update/` is removed by the next start, which the launcher makes itself.
`game/` and `saves/` are not touched; a release built from another version of
the game shows UPDATE GAME as any install of another version does.

    pes17-launcher --upgrade

does the same from a terminal. `PES17_UPDATE_URL=<address>` names another
description of the same form: a mirror's, or a file as `file://` to try an
update without publishing one.

### Reporting a bug

REPORT A BUG (`report.cpp`) starts the campaign or the multiplayer with
`PES17_REPORT=1` and `PES17_LOG_FILE=reports/run.log`, and waits for it to end;
the title one starts from its menus writes on in the same log. In that mode
the game's log names the graphics driver and ends, at exit or at a fault, with
how the run performed (`runtime/report.cpp`): the frame rate in play, how the
frame times spread, what was compiled in the middle of a draw, and where the
ring consumer's thread spent play. That last line says what holds a slow run
back: the thread itself when it is at work nearly all the time, the graphics
chip when much of that work is waiting for it, and the title's own threads or
the display when it is neither.

The launcher then writes `reports/pes17-report-<date>-<time>.txt`: the version,
the system, processor, memory, graphics and displays, the game's own summary,
and the log. An issue is public, so the log first loses the player's name, IP
addresses, the session keys of a `connect` line, account numbers, other
players' names, and the game's and the home folder's paths; the log as the
game wrote it is deleted. GitHub's new-issue page is opened with the same
description filled in, in place of the text an issue written by hand starts
with (`.github/ISSUE_TEMPLATE/issue.md`, which sends people to the launcher), and
the folder with the file beside it: the launcher
has no account to file an issue with and a page cannot be handed a file, so
the player drags it in.

The game ends cleanly when it is told to from outside, so its summary is
written. The launcher may be ended along with it (Steam's "Exit game", the
only way out on a Steam Deck in Gaming Mode): the log is then still there,
and the next start of the launcher asks whether to send it: YES makes the
report from it, NO deletes it.

## Windows

`WINDOWS=1 TITLE=mp RELEASE=1 LLVM_MINGW=<dir> ./build.sh` produces
`build-win-mp-release/pes17.exe` with `cmake/mingw-w64.cmake` (clang for
`x86_64-w64-mingw32` against the UCRT). XenonRecomp itself is still built with
the host's clang-18. The executable needs nothing beside it:

- the C++ runtime and threads are linked statically;
- `vulkan-1.dll` comes with the GPU driver, so `cmake/vulkan-windows.cmake`
  fetches the Vulkan headers and makes the import library from them;
- the executable asks for 16 MB thread stacks (Linux gives 8 MB), since the
  recompiled code nests deeply on the host stack;
- a release build is a windowed program (`-mwindows`) that attaches to the
  terminal it was started from, if any.

It needs Windows 10 1803 or later, for the placeholder mapping of guest memory.

## Release workflow

`.github/workflows/release.yml` runs by hand from the Actions tab with a version
tag and the game's version (`tu6` or `tu0`). It builds both titles with both `steam` and `lan` for Linux (Ubuntu 22.04,
so the binaries need glibc 2.35 at most, with Vulkan-Headers 1.3.275 installed
over the system's) and for Windows (cross-compiled on Ubuntu with llvm-mingw),
with ccache, then packages `pes17-sp` and `pes17-mp` with the README per platform
and service, and drafts a GitHub Release. The two executables come from a
private repository named by the secret `ASSET_REPO`, read with
`ASSET_REPO_TOKEN`, which holds `default.xex` and `default_mp.xex` at its root
and the update's two patches and three fastfiles under `title-updates/TU6/`.
It packages `pes17-launcher` with them, and the fonts' licence.

## Layout

| path | what |
|---|---|
| `build.sh` | the whole build |
| `CMakeLists.txt`, `cmake/` | the runtime's build; the Windows toolchain and Vulkan import library |
| `patches/` | local changes to XenonRecomp |
| `config/MW2.toml`, `config/MW2MP.toml` | recompiler config, campaign and multiplayer; `*.tu0.toml` for the disc version |
| `ppc/`, `ppc_mp/` | generated C++ and its generated glue (gitignored) |
| `runtime/` | the host runtime |
| `tools/` | generators, reverse-engineering scripts, capture helpers |
| `tools/routes/` | recorded walks across `mp_afghan` for `PES17_WALK_PATH` |
| `launcher/` | the launcher: install, and starting the game ([The launcher](#the-launcher)) |
| `third_party/ffmpeg-xenia/` | builds the XMA frame decoder from Xenia's FFmpeg branch, fetched at configure time |
| `third_party/fonts/` | the launcher's fonts (Barlow, SIL Open Font License) |
| `docs/` | this documentation |

### The runtime

| path | what |
|---|---|
| `main.cpp` | reserves the guest space, loads the image, starts the title, ends the run |
| `guest.h`, `guest_memory.*` | guest pointers, big-endian values, the address space |
| `env.h`, `diagnostics.h`, `log.h`, `counter.h`, `words_hash.h` | switch readers, the diagnostics gate, the log, small helpers |
| `platform.*` | what Linux and Windows spell differently |
| `title.h` | the guest addresses the runtime names, per executable |
| `install/` | a player's start: the executable check, XEX decryption, the hand-over to the launcher |
| `kernel/` | kernel and XAM imports: memory, objects and waits, threads, files, content and profile, input, networking, video, audio |
| `apu/` | the XAudio render driver and the XMA decoder |
| `online/` | the online service backends (`none`, `lan`, `steam`) |
| `gpu/` | the command processor: ring and PM4 packets, interrupts, D3D9's command-buffer arena, texture fetch and tiling, the D3D9 hooks, the write watch (`memory_watch.*`) |
| `gpu/vulkan/` | the Vulkan renderer: draws, targets, resolves, frames, pipelines and pipeline libraries, the shader translator, the texture cache, the recorder thread, the display table, the presenter window, RenderDoc capture |
| `image_move.cpp` | the image pool's block copy, which the console makes with a memory-export draw |
| `shader_preload.cpp` | hands shaders loaded with a level to the renderer to compile |
| `engine.h`, `engine_log.cpp`, `predicate_waits.cpp`, `console.cpp` | hooks into the engine: print and error paths, spin waits, the console command buffer |
| `player.cpp` | the headless walker and route recorder |
| `field_of_view.cpp` | `PES17_FOV`: scales the view angle the title computes |
| `stutters.cpp`, `pacing_trace.cpp` | the stutter detector and the frame pacing timeline |
| `report.cpp` | `PES17_REPORT=1`: the driver's name and a run's performance summary, for a bug report |
| `crash.cpp`, `watchpoint.cpp`, `mmio_hook.h` | the fault handler, the write watchpoint, the hardware-register store hook |

### Tools

| path | what |
|---|---|
| `xdvdfs.py`, `xexdump.py`, `xexinfo.py` | read the ISO; decrypt and decompress an XEX2 into a flat PE; dump its headers |
| `stfs.py`, `xexpatch.cpp` | unpack a title update's package; apply an executable patch (`.xexp`) with XenonRecomp's patcher |
| `title.py` | which executable the other tools work on (`PES17_TITLE=sp\|mp`, `PES17_VERSION=tu6\|tu0`) |
| `fixbounds.py` | explicit function boundaries for leaf functions holding jump tables |
| `genshared.py`, `gen_kernel_stubs.py` | `ppc_recomp_shared.h`, the import list, and stubs for unimplemented imports |
| `extract_shaders.py` | every shader's microcode from the fastfiles |
| `xenos_shader.py`, `xenos_isa.py` | Xenos microcode disassembler |
| `translate_shader.cpp`, `upload_texture.cpp` | the `translate-shader` and `upload-texture` tools: the shader translator and texture upload against a real driver, without the game (Linux) |
| `find_in_title.py` | finds the other executable's copy of a function by its code |
| `analyze.py`, `callgraph.py`, `xref.py`, `strings_in.py` | questions about the guest image: indirect branches, the call graph, address references, strings |
| `d3d_region.py`, `classify_d3d.py`, `resource_audit.py` | map the statically linked D3D9 ([d3d9-seam.md](d3d9-seam.md)) |
| `capture_by_hand.sh`, `capture_xenia.sh` | RenderDoc captures from this runtime or from Xenia |
| `rd_run.sh` | runs a RenderDoc analysis script and closes RenderDoc afterwards; the only way to run one |
| `rd_thumbs.sh` | the picture from every `.rdc` as a PNG, plus a contact sheet |
| `flash_hunt.sh`, `flash_hunt_report.py`, `flash_draws.py` | the flash hunt: mark flashes in play, then compare the marked frame's draws with its neighbours' |

### Tests

`translate-shader` and `upload-texture` above are harnesses to be read: they run
a stage without the game and print what it did, and a person decides whether it
looks right. `bc-bench` is a third and prints only a number — how long one
2048x2048 software block-compressed decode takes, in each format the decoder
answers for ([tools/bc_bench.cpp](../tools/bc_bench.cpp)). It is what the
figures in `runtime/gpu/vulkan/bc_decoder.cpp` are quoted from; the correctness
of that decoder is `ctest`'s `bc`, not this.

What `ctest` runs instead asserts, so it passes or fails on its own:

    cmake --build build && ctest --test-dir build --output-on-failure

They can also be configured on their own, which is what CI does: the root
`CMakeLists.txt` will not configure without the recompiled guest code, and a
runner has none of it.

    cmake -S tests -B build-tests -G Ninja
    cmake --build build-tests && ctest --test-dir build-tests --output-on-failure

Both entry points build the same five targets from `tests/CMakeLists.txt`
([.github/workflows/tests.yml](../.github/workflows/tests.yml), which runs them
on every push and pull request).

| test | what |
|---|---|
| `durable` (`tests/durable_test.cpp`) | that a save survives losing the process part-way: a replacement leaves the previous contents whole, a successful write leaves no `.tmp`, one left by a dead run is not mistaken for the target, and sizes round-trip across block boundaries ([saves.md](saves.md#surviving-an-interrupted-write)) |
| `log` (`tests/log_repeat_test.cpp`) | the rule that keeps a run readable: a line that repeats is written as it doubles with the count beside it, two lines differing only by an address are one kind, and a repetition in progress cannot flood ([switches.md](switches.md), `PES17_LOG_ALL`) |
| `bc` (`tests/bc_decoder_test.cpp`) | the software block-compressed decoder (`bc_decoder.cpp`) against a reference written from the formats themselves, over random blocks and odd sizes: DXT1's three-colour mode, DXT3's four-bit alpha, DXT5's two alpha modes, BC5's two channels, levels, short payloads, impossible formats, and that decoding into a reused output buffer gives what a fresh one gave ([textures.md](textures.md#formats)) |
| `volume` (`tests/texture_volume_test.cpp`) | where each level of a 3D texture lives in guest memory and that untiling one reads every level from its own place, against Xenia's `GetGuestTextureLayout` transcribed for the comparison — the depth term of a volume's level stride, which no desktop run could confirm ([textures.md](textures.md#layout-in-guest-memory)) |
| `version` (`tests/version_test.cpp`) | the order release tags are compared in (`launcher/version.h`, `update::Look`): that a pre-release is older than its release, that `alpha.2` is older than `alpha.10`, that the project's own `v0.1.0-alpha.13` reads, and that what is not a version is refused rather than ordered — a tag the updater cannot read is a release no player is ever offered |

None of them needs a disc, a game file or a GPU, which is the point — they run
anywhere, including on a tree that cannot build the runtime. On Windows they are
linked `-static` like the game, so one that needs a libstdc++ symbol the
shell's `PATH` cannot supply (a `std::filesystem` one, say) starts, rather than
failing with `0xc0000139` before it can run a single check.

### Docs

| file | what |
|---|---|
| [building.md](building.md) | this page |
| [runtime.md](runtime.md) | how the runtime stands in for the console |
| [switches.md](switches.md) | every `PES17_*` switch |
| [d3d9-seam.md](d3d9-seam.md) | where the title meets the GPU: the statically linked D3D9, the ring, the flip handshake |
| [shaders.md](shaders.md) | Xenos microcode translated to SPIR-V |
| [textures.md](textures.md) | fetch constants, tiling, upload and invalidation |
| [rendering.md](rendering.md) | render targets, resolves, pipeline state, gamma and MSAA |
| [gameplay.md](gameplay.md) | getting from the menu into a level |
| [multiplayer.md](multiplayer.md) | the multiplayer executable and the online services |
| [audio.md](audio.md) | the audio driver and the XMA decoder |
| [saves.md](saves.md) | content packages, saved games and the profile |

## Local changes to XenonRecomp

`patches/xenonrecomp-pes17.patch`, applied by `build.sh`:

- **`XenonRecomp/recompiler.cpp`**
  - Instructions MW2 uses that the recompiler did not handle: load/store update
    forms (`lhzu`, `lhau`, `lfsu`, `lfdu`, `sthu`, `stfsu`, `stfdu`, `stbux`,
    `lbzux`, `lhzux`, `lwzux`, `ldux`, `lfsux`, `sthux`, `stdux`), `lhbrx`,
    `dcbst` (no-op), `bdzf`, `eqv`, `addc`, `addme`, `subfze`, `mulhdu`,
    `frsqrte`, `vsubuws`, `vpkswss`/`vpkswss128`, `vcfpuxws128`, `vsel128`.
  - `vpkd3d128`/`vupkd3d128`: the 10-10-10-2 signed normalised format (x in the
    low bits, w unsigned in the top two), and `float16_2` packing.
  - A jump table switches on the low 32 bits of the index register: the guard
    ahead of it is `cmplwi`, and the high half may hold other bits.
  - A jump table's `default:` returns instead of `__builtin_unreachable()`, which
    let the compiler drop the bounds check.
  - `mftb` reads `PPC_QUERY_TIMEBASE()`, a 50 MHz counter the runtime supplies,
    instead of `__rdtsc()`.
- **`XenonAnalyse/main.cpp`**: jump-table patterns for XDK 8276's instruction
  order, which schedules the index shift between the `lis` and the `addi`; the
  table and base address pairs are located by opcode rather than fixed offset,
  and `nop` padding inside a pattern is skipped.
- **`XenonAnalyse/function.cpp`**: a `bclr` ends a function only when its BO
  ignores both the condition and the counter. `bdzlr` tests the counter, and
  treating it as a return cut `memset` short.
- **`XenonUtils/ppc_context.h`**: `simde_mm_vctuxs` (float to unsigned word with
  saturation), and the `PPC_QUERY_TIMEBASE` declaration.
