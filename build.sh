#!/bin/bash
# PES 2017 (Xbox 360) -> native ARM64 Android recompilation.
#   Prereqs: cmake, ninja, clang, python3, git, Android NDK 28.x, and the game
#            (GAME=<extracted disc folder holding default.xex>, default ../GAME).
#
#   PROFILE=safe|balanced|aggressive   how much of the guest register file the
#       generated C++ keeps in function locals (docs/RECOMP_RESEARCH.md has the
#       measurements). balanced (default) is -18% arm64 code on a sample unit and
#       only touches registers the PowerPC ABI makes dead at calls (ctr, xer, the
#       reservation, cr). aggressive adds skip_lr/skip_msr and non-volatile/argument
#       locals (-31%) and is only for a build whose guest code has been validated.
#   RECOMPILE_ONLY=1   stop once ppc/ is generated and checked (step 7)
#   JOBS=<n>           parallel compile jobs;  CCACHE=1 uses ccache when installed
set -euo pipefail
ROOT=$(cd "$(dirname "$0")" && pwd); cd "$ROOT"
GAME=${GAME:-"$ROOT/../GAME"}
PROFILE=${PROFILE:-balanced}
CMAKE_CC=${CMAKE_CC:-/usr/bin/clang}; CMAKE_CXX=${CMAKE_CXX:-/usr/bin/clang++}
JOBS=${JOBS:-$(getconf _NPROCESSORS_ONLN)}   # every core; override with JOBS=n
unset PYTHONPATH PYTHONHOME   # tools/*.py import title.py from their own directory
CFG=config/PES.active.toml

case "$PROFILE" in
    safe)       LOCALS="" ;;
    balanced)   LOCALS="ctr_as_local xer_as_local reserved_as_local cr_as_local" ;;
    aggressive) LOCALS="skip_lr skip_msr ctr_as_local xer_as_local reserved_as_local cr_as_local non_argument_as_local non_volatile_as_local" ;;
    *) echo "PROFILE must be safe, balanced or aggressive"; exit 1 ;;
esac

echo "==> 1. XenonRecomp (vendored in third_party/XenonRecomp, see UPSTREAM.md there)"
XENON=third_party/XenonRecomp
[ -f "$XENON/CMakeLists.txt" ] || { echo "$XENON is missing"; exit 1; }
echo "==> 2. build XenonRecomp / XenonAnalyse"
cmake -B $XENON/build -S $XENON -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_C_COMPILER=$CMAKE_CC -DCMAKE_CXX_COMPILER=$CMAKE_CXX >/dev/null 2>&1
cmake --build $XENON/build -j"$JOBS" >/dev/null 2>&1

echo "==> 3. the executable"
mkdir -p pes
[ -f pes/default.xex ] || cp "$GAME/default.xex" pes/default.xex
echo "==> 4. decrypt/decompress XEX -> flat PE image"
[ -f pes/default.pe ] || python3 tools/xexdump.py pes/default.xex pes/default.pe

echo "==> 5. jump tables, save/restore helpers"
./$XENON/build/XenonAnalyse/XenonAnalyse pes/default.xex config/pes_switch_tables.toml >logs-analyse.txt 2>&1
python3 tools/trim_switch_tables.py config/pes_switch_tables.toml
python3 tools/fix_switch_regs.py config/pes_switch_tables.toml --apply >/dev/null || true
# Dispatches the analyser missed (stores between the guard and the bctr): without them the bctr is an
# "indirect call" to a case label and the task that reaches it never finishes (the in-match freeze).
python3 tools/find_missed_switches.py config/pes_switch_tables.toml config/pes_switch_extra.toml
cat config/pes_switch_extra.toml >> config/pes_switch_tables.toml
echo "    tables: $(grep -c '^\[\[switch\]\]' config/pes_switch_tables.toml)"
python3 tools/find_helpers.py --write config/PES.toml >/dev/null

# The recompiler needs function bounds the analyser cannot derive. Two checks
# find them from its own output and feed them back; each pass can only grow a
# bound, so the loop ends. A pass that changes nothing is the fixed point.
#   fixbounds.py   jump-table cases outside the function (the log says which)
#   fix_ladders.py a goto to a label no function holds (read from the C++)
echo "==> 6. recompile PPC -> C++ (profile: $PROFILE)"
python3 - "$CFG" $LOCALS <<'PY'
import re, sys
s = open("config/PES.toml").read()
for key in sys.argv[2:]:
    s = re.sub(rf"^{key} = false", f"{key} = true", s, flags=re.M)
open(sys.argv[1], "w").write(s)
PY
for pass in 1 2 3 4 5; do
    rm -rf ppc && mkdir ppc
    ( cd config && ../$XENON/build/XenonRecomp/XenonRecomp PES.active.toml ../$XENON/XenonUtils/ppc_context.h ) >logs-recomp.txt 2>&1
    changed=0
    python3 tools/fixbounds.py config/pes_switch_tables.toml logs-recomp.txt --apply config/PES.toml >/dev/null || changed=1
    python3 tools/fix_ladders.py ppc --apply config/PES.toml >/dev/null 2>&1 || changed=1
    echo "    pass $pass: jump-table errors $(grep -c 'trying to jump outside function' logs-recomp.txt || true)," \
         "undecodable words $(grep -c 'Unable to decode' logs-recomp.txt || true)$([ $changed = 1 ] && echo ', bounds changed -> again')"
    [ $changed = 0 ] && break
    python3 - "$CFG" $LOCALS <<'PY'
import re, sys
s = open("config/PES.toml").read()
for key in sys.argv[2:]:
    s = re.sub(rf"^{key} = false", f"{key} = true", s, flags=re.M)
open(sys.argv[1], "w").write(s)
PY
done
[ $changed = 0 ] || { echo "bounds did not converge; see logs-recomp.txt"; exit 1; }
echo "$PROFILE" > ppc/PROFILE

echo "==> 7. declarations + kernel import stubs"
python3 tools/genshared.py
python3 tools/gen_kernel_stubs.py | head -1

[ -n "${RECOMPILE_ONLY:-}" ] && [ "$RECOMPILE_ONLY" != 0 ] && { echo "done: ppc/ has $(ls ppc | wc -l) files"; exit 0; }

echo "==> 8. build libpes17.so for arm64 Android"
# CMake and ninja run Python; with pyenv the shim needs a version (as in tools/deploy.sh).
command -v pyenv >/dev/null && export PYENV_VERSION=${PYENV_VERSION:-3.10.14}
NDK=${ANDROID_NDK_HOME:-$(ls -d "$HOME"/Library/Android/sdk/ndk/28.* "${ANDROID_HOME:-/nonexistent}"/ndk/28.* 2>/dev/null | tail -1)}
LAUNCH=""
[ "${CCACHE:-}" = 1 ] && command -v ccache >/dev/null && LAUNCH="-DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache"
cmake -S . -B build-android -G Ninja -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
      -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-26 -DANDROID_STL=c++_shared \
      -DPES17_DIAGNOSTICS=OFF -DPES17_USE_SDL=OFF -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_CXX_FLAGS_RELEASE="-O2 -DNDEBUG" $LAUNCH >logs-cmake.txt 2>&1 \
    || { tail -15 logs-cmake.txt; echo "cmake failed (logs-cmake.txt)"; exit 1; }
ninja -C build-android -j"$JOBS" pes17
ls -la build-android/libpes17.so
tools/verify_android_libs.sh build-android/libpes17.so
