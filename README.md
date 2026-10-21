# PES 2017 — Xbox 360 → Android recompilation (work in progress)

Ahead-of-time recompilation of *Pro Evolution Soccer 2017* (Xbox 360) to native
ARM64 Android code, built on the `mw2-android` runtime. Read
[docs/PORTING.md](docs/PORTING.md) for exactly what works and what is left.

```bash
GAME=../GAME ./build.sh
```

Your own disc is required; nothing from the game is in this repository.
The docs in `docs/` other than `PORTING.md` describe the MW2 port this was
derived from and are kept as reference for the shared runtime.
