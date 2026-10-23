#!/usr/bin/env python3
"""Fail when the shader cache bundled in the APK is not one this runtime reads.

A seed whose version differs from kCacheVersion (runtime/gpu/vulkan/renderer_pipelines.cpp)
is ignored at start-up ("is not a shader cache for this build"), so a fresh install compiles
every pipeline in the middle of its first match and skips the draws that wait for one. To make
a new seed, play on a phone and run tools/update_shader_seed.sh.
"""
import re
import struct
import sys
from pathlib import Path

root = Path(__file__).resolve().parent.parent
source = (root / "runtime/gpu/vulkan/renderer_pipelines.cpp").read_text()
version = int(re.search(r"kCacheVersion\s*=\s*(\d+)", source).group(1))
seed = root / "android/app/src/main/assets/shader_cache.bin"
magic, have, shaders, pipelines = struct.unpack("<4I", seed.read_bytes()[:16])
if magic != 0x32574D53 or have != version:
    sys.exit(f"{seed}: cache version {have}, runtime reads {version}; "
             "record a new seed with tools/update_shader_seed.sh")
print(f"ok: shader seed v{have}, {shaders} shaders, {pipelines} pipelines")
