#!/usr/bin/env bash
# Put what r1player needs under the mainline kernel on the SD card, in
# /.r1-mainline/: the r1player build from player/, and the stock system's
# glibc and font, copied on the R1 itself. Run it from the stock system;
# the mainline initramfs runs r1player from there.
#
#   tools/sdsync.sh
#
# The card is remounted read-write for the copy and read-only again after.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
export ADB_LIBUSB=0
bin="$here/../../player/target/mipsel-unknown-linux-gnu/release/r1player"
[ -x "$bin" ] || { echo "no r1player build: run player/dev build first"; exit 1; }

sd=$(adb shell "grep '^/dev/mmcblk0p1 ' /proc/mounts | cut -d' ' -f2" | tr -d '\r')
[ -n "$sd" ] || { echo "the SD card is not mounted on the R1"; exit 1; }
dir="$sd/.r1-mainline"

# The loader and the libraries r1player links against (readelf -d).
libs="/lib/ld.so.1 /lib/libc.so.6 /lib/libm.so.6 /lib/libpthread.so.0 /lib/libdl.so.2"
status=0
adb shell "mount -o remount,rw $sd && mkdir -p $dir/lib && cp -L $libs $dir/lib/ &&
	cp /usr/resource/fonts/default.otf $dir/" || status=1
[ $status = 0 ] && { adb push "$bin" "$dir/r1player" >/dev/null || status=1; }
adb shell "chmod 755 $dir/r1player 2>/dev/null; sync; mount -o remount,ro $sd"
[ $status = 0 ] || { echo "copy failed; the card is read-only again"; exit 1; }
adb shell "ls -la $dir $dir/lib" | tr -d '\r'
