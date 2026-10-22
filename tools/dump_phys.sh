#!/usr/bin/env bash
# Pull the game's 512 MB guest physical bank off a rooted phone: tools/dump_phys.sh [out=phys.bin]
# (virtual address v = 0x80000000 + physical; the image is at physical 0x02000000 + (v - 0x82000000)).
OUT=${1:-phys.bin}
cat > /tmp/dp.sh <<'S'
PID=$(pidof com.pes2017.recomp:game)
START=$(grep mw2-physical /proc/$PID/maps | head -1 | cut -d- -f1)
dd if=/proc/$PID/mem of=/data/local/tmp/phys.bin bs=4096 skip=$((0x$START / 4096)) count=131072 2>/dev/null
chmod 644 /data/local/tmp/phys.bin
S
adb push /tmp/dp.sh /data/local/tmp/dp.sh >/dev/null && adb shell su -c "sh /data/local/tmp/dp.sh" && adb pull /data/local/tmp/phys.bin "$OUT" >/dev/null && ls -la "$OUT"
