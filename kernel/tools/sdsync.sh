#!/usr/bin/env bash
# Put what r1player needs under the mainline kernel on the SD card, in
# /.r1-mainline/: the r1player build from player/, the stock system's glibc
# and font, copied on the R1 itself, and the mainline kernel (out/) with
# r1jump. Run it from the stock system; the firmware jumps into that kernel
# at every start, and its initramfs runs r1player from there.
#
#   tools/sdsync.sh
#
# The card is remounted read-write for the copy and read-only again after.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
export ADB_LIBUSB=0
bin="$here/../../player/target/mipsel-unknown-linux-gnu/release/r1player"
out="$here/../out"
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
# The mainline kernel and r1jump, which the firmware's r1-mainline.sh jumps
# into at every start, and the kernel's entry point for r1jump.
if [ $status = 0 ] && [ -f "$out/r1-linux.bin" ]; then
	entry=0x$(grep ' kernel_entry$' "$out/System.map" | cut -c9-16)
	adb push "$out/r1-linux.bin" "$dir/r1-linux.bin" >/dev/null &&
		adb push "$here/stock-modules/r1jump/r1jump.ko" "$dir/r1jump.ko" >/dev/null &&
		adb shell "echo $entry > $dir/entry" || status=1
fi
adb shell "chmod 755 $dir/r1player 2>/dev/null; sync; mount -o remount,ro $sd"
# The remount has been seen to leave the card read-write (2026-10-23): check.
ro() { adb shell "grep ' $sd ' /proc/mounts" | grep -q " ro,"; }
ro || { sleep 1; adb shell "sync; mount -o remount,ro $sd"; }
ro || { echo "the card is still mounted read-write: remount it read-only"; exit 1; }
[ $status = 0 ] || { echo "copy failed; the card is read-only again"; exit 1; }
adb shell "ls -la $dir $dir/lib" | tr -d '\r'
