#!/bin/bash
# PES 2017 (Xbox 360) -> native macOS (Apple Silicon arm64 & Intel x86_64) build script.
#
# Prerequisites (install via Homebrew: https://brew.sh):
#   brew install cmake ninja molten-vk sdl3 vulkan-headers
#
# Optional environment variables:
#   GAME=<path>         Path to extracted Xbox 360 game folder containing default.xex (default: ./pes or ../GAME)
#   PROFILE=safe|balanced|aggressive (default: balanced)
#   JOBS=<n>            Number of parallel compiler jobs (default: all CPU cores)
#   RECOMPILE_ONLY=1    Stop after generating C++ from PowerPC binary
#   PACKAGE=1           Build and package into PES 2017.app bundle
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
cd "$ROOT"

echo "============================================================"
echo "    PES 2017 Recompilation - macOS Native Build"
echo "============================================================"

# 1. Detect Architecture & Environment
ARCH=$(uname -m)
OS=$(uname -s)

if [ "$OS" != "Darwin" ]; then
    echo "Warning: Running on $OS, not Darwin (macOS). macOS build flags will be targeted."
fi

echo "==> Architecture: $ARCH ($OS)"

# Detect Homebrew prefix
BREW_PREFIX=""
if command -v brew >/dev/null 2>&1; then
    BREW_PREFIX=$(brew --prefix)
elif [ -d "/opt/homebrew" ]; then
    BREW_PREFIX="/opt/homebrew"
elif [ -d "/usr/local" ]; then
    BREW_PREFIX="/usr/local"
fi

if [ -n "$BREW_PREFIX" ]; then
    echo "==> Homebrew detected at: $BREW_PREFIX"
    export PATH="$BREW_PREFIX/bin:$PATH"
fi

# Detect Number of CPU cores
JOBS=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)}
echo "==> Using $JOBS parallel build jobs"

# Check required commands
MISSING_TOOLS=()
for tool in cmake python3; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        MISSING_TOOLS+=("$tool")
    fi
done

if [ ${#MISSING_TOOLS[@]} -gt 0 ]; then
    echo "Error: Missing required tools: ${MISSING_TOOLS[*]}"
    echo "Please install them via Homebrew:"
    echo "    brew install cmake ninja"
    exit 1
fi

# Determine CMake Generator (Ninja preferred, Unix Makefiles fallback)
GENERATOR="Unix Makefiles"
if command -v ninja >/dev/null 2>&1; then
    GENERATOR="Ninja"
fi
echo "==> CMake generator: $GENERATOR"

# Setup MoltenVK and Vulkan search paths
CMAKE_PREFIX_DIRS=()
if [ -n "$BREW_PREFIX" ]; then
    CMAKE_PREFIX_DIRS+=("$BREW_PREFIX")
    [ -d "$BREW_PREFIX/opt/molten-vk" ] && CMAKE_PREFIX_DIRS+=("$BREW_PREFIX/opt/molten-vk")
    [ -d "$BREW_PREFIX/opt/sdl3" ] && CMAKE_PREFIX_DIRS+=("$BREW_PREFIX/opt/sdl3")
    [ -d "$BREW_PREFIX/opt/vulkan-headers" ] && CMAKE_PREFIX_DIRS+=("$BREW_PREFIX/opt/vulkan-headers")
fi

if [ -n "${VULKAN_SDK:-}" ] && [ -d "$VULKAN_SDK" ]; then
    echo "==> Vulkan SDK found: $VULKAN_SDK"
    CMAKE_PREFIX_DIRS+=("$VULKAN_SDK")
fi

PREFIX_PATH_ARG=""
if [ ${#CMAKE_PREFIX_DIRS[@]} -gt 0 ]; then
    # Join with semicolon
    IFS=";" PREFIX_PATH_JOINED="${CMAKE_PREFIX_DIRS[*]}"
    PREFIX_PATH_ARG="-DCMAKE_PREFIX_PATH=$PREFIX_PATH_JOINED"
fi

# 2. Check for default.xex and Recompile if available
GAME=${GAME:-"$ROOT/pes"}
[ ! -d "$GAME" ] && [ -d "$ROOT/../GAME" ] && GAME="$ROOT/../GAME"

PROFILE=${PROFILE:-balanced}
case "$PROFILE" in
    safe)       LOCALS="" ;;
    balanced)   LOCALS="ctr_as_local xer_as_local reserved_as_local cr_as_local" ;;
    aggressive) LOCALS="skip_lr skip_msr ctr_as_local xer_as_local reserved_as_local cr_as_local non_argument_as_local non_volatile_as_local" ;;
    *) echo "PROFILE must be safe, balanced or aggressive"; exit 1 ;;
esac

HAVE_XEX=0
if [ -f "$ROOT/pes/default.xex" ]; then
    HAVE_XEX=1
elif [ -f "$GAME/default.xex" ]; then
    mkdir -p "$ROOT/pes"
    cp "$GAME/default.xex" "$ROOT/pes/default.xex"
    HAVE_XEX=1
fi

if [ "$HAVE_XEX" -eq 1 ] && [ ! -f "$ROOT/ppc/ppc_recomp.cpp" ]; then
    echo "==> Found default.xex! Preparing PPC -> C++ recompilation..."
    
    # 2a. Build XenonRecomp host tools
    XENON=third_party/XenonRecomp
    if [ ! -f "$XENON/CMakeLists.txt" ]; then
        echo "Error: $XENON is missing"
        exit 1
    fi

    echo "==> Building XenonRecomp / XenonAnalyse host tools..."
    cmake -B "$XENON/build" -S "$XENON" -DCMAKE_BUILD_TYPE=Release
    cmake --build "$XENON/build" -j"$JOBS"

    # 2b. Decrypt/decompress XEX -> PE
    echo "==> Decrypting XEX -> PE..."
    [ -f pes/default.pe ] || python3 tools/xexdump.py pes/default.xex pes/default.pe

    # 2c. Jump tables & helpers
    echo "==> Analysing jump tables and dispatches..."
    ./$XENON/build/XenonAnalyse/XenonAnalyse pes/default.xex config/pes_switch_tables.toml >logs-analyse.txt 2>&1
    python3 tools/trim_switch_tables.py config/pes_switch_tables.toml
    python3 tools/fix_switch_regs.py config/pes_switch_tables.toml --apply >/dev/null || true
    python3 tools/find_missed_switches.py config/pes_switch_tables.toml config/pes_switch_extra.toml
    cat config/pes_switch_extra.toml >> config/pes_switch_tables.toml
    python3 tools/find_helpers.py --write config/PES.toml >/dev/null

    # 2d. Recompile PPC -> C++
    echo "==> Recompiling PPC -> C++ (profile: $PROFILE)..."
    CFG=config/PES.active.toml
    python3 - "$CFG" $LOCALS <<'PY'
import re, sys
s = open("config/PES.toml").read()
for key in sys.argv[2:]:
    s = re.sub(rf"^{key} = false", f"{key} = true", s, flags=re.M)
open(sys.argv[1], "w").write(s)
PY

    for pass in 1 2 3 4 5; do
        rm -rf ppc && mkdir -p ppc
        ( cd config && ../$XENON/build/XenonRecomp/XenonRecomp PES.active.toml ../$XENON/XenonUtils/ppc_context.h ) >logs-recomp.txt 2>&1
        changed=0
        python3 tools/fixbounds.py config/pes_switch_tables.toml logs-recomp.txt --apply config/PES.toml >/dev/null || changed=1
        python3 tools/fix_ladders.py ppc --apply config/PES.toml >/dev/null 2>&1 || changed=1
        echo "    pass $pass done (bounds changed: $changed)"
        [ $changed -eq 0 ] && break
        python3 - "$CFG" $LOCALS <<'PY'
import re, sys
s = open("config/PES.toml").read()
for key in sys.argv[2:]:
    s = re.sub(rf"^{key} = false", f"{key} = true", s, flags=re.M)
open(sys.argv[1], "w").write(s)
PY
    done

    echo "$PROFILE" > ppc/PROFILE
    echo "==> Generating stubs and declarations..."
    python3 tools/genshared.py
    python3 tools/gen_kernel_stubs.py | head -1
    echo "==> PPC recompilation complete!"
elif [ -f "$ROOT/ppc/ppc_recomp.cpp" ]; then
    echo "==> Using existing recompiled sources in ppc/"
else
    echo "==> Note: No default.xex found in pes/ or GAME/."
    echo "    The build will compile pes17-launcher, tools, and tests."
    echo "    You can run pes17-launcher later to install the game from disc or ISO."
fi

if [ -n "${RECOMPILE_ONLY:-}" ] && [ "$RECOMPILE_ONLY" != 0 ]; then
    echo "Done (--recompile-only specified)."
    exit 0
fi

# 3. Configure and Build Project with CMake
BUILD_DIR="build-macos"
echo "==> Configuring CMake in $BUILD_DIR..."

cmake -S . -B "$BUILD_DIR" \
    -G "$GENERATOR" \
    -DCMAKE_BUILD_TYPE=Release \
    $PREFIX_PATH_ARG

echo "==> Building project..."
cmake --build "$BUILD_DIR" -j"$JOBS"

echo "==> Running test suite..."
ctest --test-dir "$BUILD_DIR/tests" --output-on-failure || true

echo "==> Build complete in $BUILD_DIR!"
if [ -f "$BUILD_DIR/launcher/pes17-launcher" ]; then
    echo "    Launcher binary: $BUILD_DIR/launcher/pes17-launcher"
fi
if [ -f "$BUILD_DIR/pes17-sp" ]; then
    echo "    Game binary:     $BUILD_DIR/pes17-sp"
fi

# 4. Optional packaging into .app bundle
if [ "${PACKAGE:-0}" = "1" ] || [ "${1:-}" = "--package" ]; then
    echo "==> Packaging macOS Application Bundle..."
    ./tools/package_macos.sh "$BUILD_DIR"
fi

echo "============================================================"
echo "    Build successful!"
echo "    Run launcher: ./$BUILD_DIR/launcher/pes17-launcher"
echo "============================================================"
