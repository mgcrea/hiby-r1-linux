#!/usr/bin/env bash
# Put what the app needs under the mainline kernel on the SD card, in
# /.r1-mainline/: the app build in $R1_APP (if given), the stock system's
# glibc and font, copied on the R1 itself, and the mainline kernel (out/)
# with r1jump. Run it from the stock system; the firmware jumps into that
# kernel at every start, and its initramfs runs the app from there.
#
#   [R1_APP=APP] tools/sdsync.sh
#
# The card is remounted read-write for the copy and read-only again after.
# It copies kernel/out/ as it is: the last build.sh, tested or not.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
export ADB_LIBUSB=0
bin="${R1_APP:-}"
out="$here/../out"
[ -z "$bin" ] || [ -x "$bin" ] || { echo "$bin: no such app build"; exit 1; }

sd=$(adb shell "grep '^/dev/mmcblk0p1 ' /proc/mounts | cut -d' ' -f2" | tr -d '\r')
[ -n "$sd" ] || { echo "the SD card is not mounted on the R1"; exit 1; }
dir="$sd/.r1-mainline"

# The loader and the libraries the app links against (readelf -d).
libs="/lib/ld.so.1 /lib/libc.so.6 /lib/libm.so.6 /lib/libpthread.so.0 /lib/libdl.so.2"
status=0
adb shell "mount -o remount,rw $sd && mkdir -p $dir/lib && cp -L $libs $dir/lib/ &&
	cp /usr/resource/fonts/default.otf $dir/" || status=1
[ $status = 0 ] && [ -n "$bin" ] && { adb push "$bin" "$dir/app" >/dev/null || status=1; }
# Bluetooth (initramfs/r1-bt): the stock BlueZ, dbus and bluez-alsa with the
# libraries they link against (readelf -d, followed, plus
# libnss_files and libgcc_s, which glibc loads at run time: for dbus's user
# lookups, and for pthread_cancel, without which bluealsa aborts when a
# stream ends), the chip's firmware
# under the name btbcm asks for, picked by module as the stock bt_init does
# (0x81: aw-nb372sm, otherwise AP6212).
btbins="/usr/bin/dbus-daemon /usr/libexec/bluetooth/bluetoothd /usr/bin/bluealsa
	/usr/bin/bluealsa-aplay /usr/bin/bluealsa-cli /usr/bin/bluetoothctl /usr/bin/hciconfig
	/usr/bin/hcitool"
btlibs="/usr/lib/libasound.so.2 /usr/lib/libbluetooth.so.3 /usr/lib/libdbus-1.so.3
	/usr/lib/libexpat.so.1 /usr/lib/libfdk-aac.so.2 /usr/lib/libffi.so.7
	/usr/lib/libgio-2.0.so.0 /usr/lib/libglib-2.0.so.0 /usr/lib/libgmodule-2.0.so.0
	/usr/lib/libgobject-2.0.so.0 /usr/lib/libldacBT_abr.so.2 /usr/lib/libldacBT_enc.so.2
	/usr/lib/libldacdec.so /usr/lib/libncurses.so.6 /usr/lib/libopenaptx.so
	/usr/lib/libpcre.so.1 /usr/lib/libreadline.so.8 /usr/lib/libsbc.so.1 /usr/lib/libz.so.1
	/lib/libresolv.so.2 /lib/librt.so.1 /lib/libnss_files.so.2 /lib/libgcc_s.so.1"
btbins=$(echo $btbins) btlibs=$(echo $btlibs)	# one line each, for adb shell
[ $status = 0 ] && { adb shell "mkdir -p $dir/bt $dir/lib/firmware/brcm && cp $btbins $dir/bt/ &&
	cp -L $btlibs $dir/lib/ &&
	v=\$(cat /sys/devices/platform/md_ingenic,mmc.0/mmc_host/mmc0/mmc0:0001/mmc0:0001:2/chipvendor 2>/dev/null) &&
	case \$v in 0x81|'') fw=BCM4343A1_001.002.009.0122.0538.hcd;; *) fw=BCM4343A1_001.002.009.1010.1030.hcd;; esac &&
	cp /lib/firmware/bt_bcm/\$fw $dir/lib/firmware/brcm/BCM43430A1.hcd && echo \"Bluetooth firmware: \$fw\"" || status=1; }
# ADB under mainline (initramfs/r1-usb): the stock adbd, which talks
# FunctionFS, and the libraries it needs besides glibc and libz (libcrypto
# needs libatomic).
[ $status = 0 ] && { adb shell "cp /usr/bin/adbd $dir/ && cp -L /usr/lib/libcrypto.so.1.1 /lib/libcrypt.so.1 /lib/libatomic.so.1 $dir/lib/" || status=1; }
# The mainline kernel and r1jump, which the firmware's r1-mainline.sh jumps
# into at every start, and the kernel's entry point for r1jump.
if [ $status = 0 ] && [ -f "$out/r1-linux.bin" ]; then
	entry=0x$(grep ' kernel_entry$' "$out/System.map" | cut -c9-16)
	adb push "$out/r1-linux.bin" "$dir/r1-linux.bin" >/dev/null &&
		adb push "$here/stock-modules/r1jump/r1jump.ko" "$dir/r1jump.ko" >/dev/null &&
		adb shell "echo $entry > $dir/entry" || status=1
fi
adb shell "chmod 755 $dir/app 2>/dev/null; sync; mount -o remount,ro $sd"
# The remount has been seen to leave the card read-write (2026-10-23): check.
ro() { adb shell "grep ' $sd ' /proc/mounts" | grep -q " ro,"; }
ro || { sleep 1; adb shell "sync; mount -o remount,ro $sd"; }
ro || { echo "the card is still mounted read-write: remount it read-only"; exit 1; }
[ $status = 0 ] || { echo "copy failed; the card is read-only again"; exit 1; }
adb shell "ls -la $dir $dir/lib" | tr -d '\r'
