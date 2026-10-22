#!/usr/bin/env bash
# Rebuild the native library (all cores), package it WITHOUT recompiling the
# generated tree a second time, install on the connected phone, launch, and
# capture the runtime's log (game.log on the phone; tools/logtail.sh reads it).
#   usage: tools/deploy.sh [seconds-to-watch=25] [log-file=logs-device.txt]
# Needs ./build.sh to have run once (build-android/ configured, ppc/ built).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd); cd "$ROOT"
WATCH=${1:-25}; LOG=${2:-logs-device.txt}
export ANDROID_HOME=${ANDROID_HOME:-$HOME/Library/Android/sdk}
NDK=${ANDROID_NDK_ROOT:-$(ls -d "$ANDROID_HOME"/ndk/28.* | tail -1)}
BIN=$NDK/toolchains/llvm/prebuilt/darwin-x86_64/bin
PKG=com.pes2017.recomp

echo "==> native (every core)"
if ! PYENV_VERSION=${PYENV_VERSION:-3.10.14} ninja -C build-android -j"$(getconf _NPROCESSORS_ONLN)" mw2 > build-android/last-build.txt 2>&1; then
    grep -E "error:|FAILED" build-android/last-build.txt | grep -v "^/.*clang++" | head -15
    echo "BUILD FAILED -- not deploying (full output: build-android/last-build.txt)"; exit 1
fi
tail -1 build-android/last-build.txt

echo "==> package"
STAGE=$ROOT/build-android/stage/arm64-v8a; mkdir -p "$STAGE"
cp build-android/libmw2.so "$STAGE/" && "$BIN/llvm-strip" --strip-debug "$STAGE/libmw2.so"
# libadrenotools' hook libraries, which load an imported (Turnip) driver.
for hook in build-android/adrenotools/src/hook/lib*_hook.so build-android/adrenotools/src/hook/libhook_impl.so; do
    [ -f "$hook" ] && cp "$hook" "$STAGE/"
done
cp "$NDK/toolchains/llvm/prebuilt/darwin-x86_64/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so" "$STAGE/"
tools/verify_android_libs.sh "$STAGE/libmw2.so"
( cd android && sh ./gradlew --no-daemon -q :app:assembleRelease -PprebuiltNative="$ROOT/build-android/stage" 2>&1 | grep -vE "^w:|warning" | tail -5 || true )

echo "==> install + launch"
adb install -r android/app/build/outputs/apk/release/app-release.apk | tail -1
adb shell am force-stop $PKG
adb shell am start -n $PKG/com.mw2.recomp.MainActivity >/dev/null
sleep "$WATCH"
tools/logtail.sh run > "$LOG"
echo "==> $LOG: $(wc -l < "$LOG") lines; runtime lines below (errors/warnings first)"
tools/logtail.sh errors | head -25 || true
adb logcat -d -b crash | tail -20 || true   # native crashes land here, not in game.log
