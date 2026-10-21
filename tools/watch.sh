#!/usr/bin/env bash
# Live watcher for the phone's game.log. Prints ONE short line per new kind of
# problem (so a Monitor on it wakes the assistant at once) and saves context to
# logs-events/<n>.txt: the 60 lines around it, and for fatal ones a debuggerd
# stack dump of every thread (needs su).
#
#   tools/watch.sh                 watch the current/next run
#   WATCH_PATTERN='extra|regex'    extra patterns to report
#   WATCH_DUMP=0                   no debuggerd dump on fatal events
#
# Fatal: crash/fault, KeBugCheck, "unimplemented", process exit.
set -uo pipefail
cd "$(dirname "$0")/.."
LOG=/sdcard/Android/data/com.pes2017.recomp/files/game.log
PKG=com.pes2017.recomp
OUT=logs-events; mkdir -p "$OUT"
FATAL='SIGSEGV|SIGBUS|SIGILL|SIGABRT|fault backtrace|KeBugCheck|BUGCHECK|Fatal signal|terminate called'
SOFT='unimplemented|not implemented|Unimplemented|renderer: .*not usable|non-finite|pm4: .*invalid|skipped: [^n]|failed|FAILED'
EXTRA="${WATCH_PATTERN:-}"
PAT="$FATAL|$SOFT${EXTRA:+|$EXTRA}"
seen=" "; n=0
adb shell "tail -n 0 -F $LOG" 2>/dev/null | while IFS= read -r line; do
    echo "$line" >> "$OUT/ring.txt"
    [ "$(wc -l < "$OUT/ring.txt")" -gt 400 ] && tail -n 200 "$OUT/ring.txt" > "$OUT/ring.tmp" && mv "$OUT/ring.tmp" "$OUT/ring.txt"
    echo "$line" | grep -qE "$PAT" || continue
    key=$(echo "$line" | sed -E 's/[0-9A-Fa-f]{6,}/X/g; s/[0-9]+/N/g' | cut -c1-90)
    case "$seen" in *"|$key|"*) continue;; esac
    seen="$seen|$key|"; n=$((n+1))
    cp "$OUT/ring.txt" "$OUT/$n.txt"
    kind=SOFT; echo "$line" | grep -qE "$FATAL" && kind=FATAL
    echo "[watch #$n $kind] $(echo "$line" | cut -c1-200)  (context: $OUT/$n.txt)"
    if [ "$kind" = FATAL ] && [ "${WATCH_DUMP:-1}" = 1 ]; then
        pid=$(adb shell pidof $PKG:game | tr -d '\r')
        [ -n "$pid" ] && adb shell su -c "debuggerd -b $pid" > "$OUT/$n.stacks.txt" 2>&1 && echo "[watch #$n] stacks: $OUT/$n.stacks.txt"
    fi
done
