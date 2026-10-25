#!/usr/bin/env bash
# Write the system image (out/system.squashfs, from tools/mksystem.py) into
# the R1's `rootfs` slot (mtd2), over ADB from mainline. The running system
# comes from that slot (/rom), so the R1 first restarts on the copies
# tools/sdsync.sh put on the card (`no-rom` on the card tells init to), the
# slot is written and read back, and the R1 restarts on the new image.
#
#   tools/system-install.sh [--dry-run]
#
# --dry-run checks everything and stops before the first restart. If a step
# fails after it, `no-rom` stays and the R1 keeps running from the card:
# remove /.r1-mainline/no-rom once the slot holds a working image again.
# Volume Up held at power-on, with an r1.upt at the card root, puts stock's
# root filesystem back, which init uses as well.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
export ADB_LIBUSB=0
img="$here/../out/system.squashfs"
flasher="$here/../out/r1flash"
dry=0
[ "${1:-}" = --dry-run ] && dry=1

[ -f "$img" ] || { echo "no $img: run tools/mksystem.py"; exit 1; }
[ -x "$flasher" ] || { echo "no $flasher: run build.sh"; exit 1; }
size=$(wc -c < "$img" | tr -d " ")
[ "$size" -le $((0x2d00000)) ] || { echo "the image is $size bytes, over the 45 MiB slot"; exit 1; }
[ "$(head -c 4 "$img")" = hsqs ] || { echo "not a squashfs image"; exit 1; }
md5=$(md5 -q "$img" 2>/dev/null || md5sum "$img" | cut -d' ' -f1)

# Its stdin from /dev/null: adb shell would otherwise eat the confirmation.
r1() { adb shell "$1" < /dev/null | tr -d '\r'; }
wait_r1() {
	for _ in $(seq 1 60); do
		adb devices | grep -q 'device$' && return 0
		sleep 1
	done
	echo "the R1 didn't come back on ADB within a minute"
	return 1
}
restart() {
	r1 "sync; /sbin/r1-reboot" >/dev/null || true
	sleep 15
	wait_r1
}

case "$(r1 'uname -r')" in
7.*) ;;
*) echo "the R1 isn't on mainline with ADB"; exit 1 ;;
esac
[ "$(r1 "grep '^mtd2:' /proc/mtd")" = 'mtd2: 02d00000 00020000 "rootfs"' ] || { echo "unexpected mtd2:"; r1 'cat /proc/mtd'; exit 1; }
sd=/mnt/sd_0
dir=$sd/.r1-mainline
r1 "grep -q '^/dev/mmcblk0p1 $sd ' /proc/mounts && [ ! -e /tmp/sd-shared ]" ||
	{ echo "the SD card is not mounted on the R1 (shared with a computer?)"; exit 1; }
for f in lib/ld.so.1 lib/libc.so.6 adbd bt/bluetoothd default.otf; do
	r1 "[ -e $dir/$f ]" || { echo "the card lacks $f (tools/sdsync.sh): the R1 couldn't run without the slot"; exit 1; }
done
echo "slot now: $(r1 'head -1 /rom/etc/r1-system 2>/dev/null || echo "stock root filesystem"')"
echo "image:    $size bytes, md5 $md5"
if [ $dry = 1 ]; then
	echo "dry run: stopping before the restart"
	exit 0
fi
printf "Type flash to restart on the card's copies and write mtd2: "
read -r answer
[ "$answer" = flash ] || { echo "not written"; exit 1; }

echo "restarting on the card's copies"
r1 "mount -o remount,rw $sd && touch $dir/no-rom; sync; mount -o remount,ro $sd"
restart
[ -z "$(r1 "grep ' /rom ' /proc/mounts")" ] || { echo "/rom is still mounted: nothing written"; exit 1; }

r1 "mount -o remount,rw $sd"
adb push "$img" "$dir/system.squashfs" >/dev/null
adb push "$flasher" /tmp/r1flash >/dev/null
[ "$(r1 "md5sum $dir/system.squashfs | cut -d' ' -f1")" = "$md5" ] || { echo "the copy on the card differs: nothing written"; exit 1; }
r1 "chmod 755 /tmp/r1flash; /tmp/r1flash write /dev/mtd2 $dir/system.squashfs"
back=$(r1 "head -c $size /dev/mtd2 | md5sum | cut -d' ' -f1")
if [ "$back" != "$md5" ]; then
	r1 "sync; mount -o remount,ro $sd"
	echo "READ-BACK DIFFERS ($back): no-rom stays, so the R1 keeps running from the card"
	exit 1
fi
r1 "rm -f $dir/system.squashfs $dir/no-rom /tmp/r1flash; sync; mount -o remount,ro $sd"
echo "written and read back ($md5); restarting on it"
restart
echo "now: $(r1 'head -1 /rom/etc/r1-system')"
echo "adbd: $(r1 'readlink /proc/$(pidof adbd)/exe'), bluetoothd: $(r1 'readlink /proc/$(pidof bluetoothd)/exe'), r1player: $(r1 'pidof r1player || echo "not running"')"
