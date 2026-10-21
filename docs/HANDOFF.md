# Handoff: the Exhibition match renders correctly (2026-10-21, late)

Pick this up from the Claude CLI in `pes2017-android/`. The phone is the rooted S20 FE (`RR8RB04X2SV`).
- Runtime changes: `tools/deploy.sh` (about 1 min including the APK).
- `ppc/` or `runtime/mmio_hook.h` changes: `RECOMPILE_ONLY=1 GAME=../GAME ./build.sh`, then `PYENV_VERSION=3.10.14 ninja -C build-android mw2` (about 30 min).
- `tools/to_match.sh [prefix] [shots] [kickoff|prematch|teams]` reaches kick-off in about 60 s.

## Where things stand

| Step | State |
|---|---|
| Boot → menus → Exhibition → team select → pre-match (3D player preview) | works |
| Match: green striped pitch, lighting and stadium shadows, crowd, kits, HUD, radar | works, 40–53 fps |

All fixes and their evidence are in `docs/PORTING.md`:
- "Memory for the match load" (out-of-memory, leak, function table).
- "The match: a stack the recompiled code left unbalanced" (jump-table registers, fixbounds).
- "The dark match image" (8 causes, including resolve write-back).

## Late session (2026-10-21 evening)

See PORTING.md, "Kits, crowd, performance". Steady match at 52 fps. Kits are correct and checked by `tools/kits.sh`. The crowd is still missing.

Open, in order:
1. **60 fps:** about 3 ms short, and heat throttles the phone above about 68 °C. Next levers:
   - A fractional scene-only render scale (WWE's `native_render_scale`: `HostWidth()`/`HostHeight()`, effects at 1x).
   - Fold the EDRAM clears into render-pass load ops (pinyon A60-1, −1.6 to −2.6 ms).
   - Async or compute BC decode.
   - `Surface.setFrameRate(60)`.
2. **Goal kick at 20 fps:** not reproduced yet. Use `tools/pad.sh` to force one.
3. **Crowd:** billboards are placed right; check the atlas sampling.
4. **"shader not translated":** about 160 draws during load and intro; pixel shader depth export 61.

## Next candidates

1. **First-run shader compile.** Pipelines compile in the background and draws are skipped until ready. Bumping `kCacheVersion` (now 5) resets the shader cache. Warm-up runs only in menus and cutscenes.
2. **Gameplay input.** The touch layout is still MW2's (LT/RT AIM/FIRE etc.); PES needs pass/shoot/through/sprint.
3. **Audio** (XMA through XAudio2) is untested in the match.
4. **Remaining open renderer items:**
   - "pixel shader … depth export 61 is not translated yet".
   - Resolution scale > 1 for param gen (FragCoord is not divided by the scale).
   - `ClearAliasedColour` covers zero clears only.
5. **Performance:** CPU-decoded BC textures (Adreno 650 has no BC), and the vertex shadow is off.

## Debug tools

- `files/dump_frame`: draws, `ps c*` constants, `DUMP resolve`, `resolve clear`, `skipped`, `samples …`, and `files/frame_images/*.pnm`.
- `files/draw_range` (`"lo hi"`), `files/skip_ps` (pixel shader hashes), `dump_guest`, `watch_guest`, `report_memory`.
- `tools/xenos_disasm.py` (ALU and fetch disassembler), `tools/gen_r1_probes.py`, `tools/fix_switch_regs.py`.
