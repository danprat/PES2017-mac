#!/usr/bin/env bash
# Copy the shader cache a phone has recorded into the APK's seed. Play first (the cache grows
# with every pipeline a session needs and is written when the game is paused or closed), and
# keep the phone's cache from an earlier session so the seed is the union of them.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
adb pull /sdcard/Android/data/com.pes2017.recomp/files/shader_cache.bin "$ROOT/android/app/src/main/assets/shader_cache.bin"
python3 "$ROOT/tools/check_shader_seed.py"
