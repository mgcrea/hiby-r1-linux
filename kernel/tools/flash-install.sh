#!/usr/bin/env bash
# Write the mainline flash kernel (out/r1-linux.uimage) into the R1's
# `kernel` slot (mtd1), over ADB, from mainline or from the stock system.
# The stock SPL then boots it at every start; its r1-loader hands over to
# the kernel on the card (/.r1-mainline/r1-linux.bin) by kexec, and falls
# back to itself when that one failed to come up. Run it only with the
# user's go: it replaces the kernel the R1 boots (docs/kernel.md,
# "Replacing stock in flash").
#
#   tools/flash-install.sh [--dry-run]
#
# --dry-run does everything but the erase and the write. From mainline the
# writing is done by out/r1flash (tools/r1flash.c), pushed to /tmp; from
# stock by its mtd-utils. The way back: Volume Up held while the R1 starts,
# with a stock or auto-jump r1.upt at the card root, rewrites `kernel` and
# `rootfs` from it (the recovery in `kernel2`/`rootfs2`, which this leaves
# alone, as `uboot` and `ota`).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
export ADB_LIBUSB=0
img="$here/../out/r1-linux.uimage"
flasher="$here/../out/r1flash"
dry=0
[ "${1:-}" = --dry-run ] && dry=1

[ -f "$img" ] || { echo "no $img: run build.sh"; exit 1; }
size=$(wc -c < "$img" | tr -d " ")
[ "$size" -le 5242880 ] || { echo "the image is $size bytes, over the 5 MiB slot"; exit 1; }
[ "$(head -c 4 "$img" | od -An -tx1 | tr -d ' \n')" = 27051956 ] || { echo "not a uImage"; exit 1; }
md5=$(md5 -q "$img" 2>/dev/null || md5sum "$img" | cut -d' ' -f1)

# Its stdin from /dev/null: adb shell would otherwise eat the confirmation.
r1() { adb shell "$1" < /dev/null | tr -d '\r'; }
case "$(r1 'uname -r')" in
4.4.94+) system=stock ;;
7.*) system=mainline ;;
*) echo "the R1 isn't on ADB (or runs an unknown kernel)"; exit 1 ;;
esac
[ "$(r1 "grep '^mtd1:' /proc/mtd")" = 'mtd1: 00500000 00020000 "kernel"' ] || { echo "unexpected mtd1:"; r1 'cat /proc/mtd'; exit 1; }
sd=$(r1 "grep '^/dev/mmcblk0p1 ' /proc/mounts | cut -d' ' -f2")
[ -n "$sd" ] || { echo "the SD card is not mounted on the R1 (shared with a computer?)"; exit 1; }
dir=$sd/.r1-mainline

echo "R1 on $system"
echo "slot now: $(r1 'head -c 64 /dev/mtd1 | tail -c 32 | tr -d "\000"')"
echo "image:    $(head -c 64 "$img" | tail -c 32 | tr -d '\000'), $size bytes, md5 $md5"

r1 "mount -o remount,rw $sd"
trap 'r1 "sync; mount -o remount,ro $sd" >/dev/null' EXIT
if [ $system = stock ]; then
	# The image goes to the card: stock's /tmp is RAM, with about 15 MB free.
	src=$dir/r1-linux.uimage
	adb push "$img" "$src" >/dev/null
	r1 "[ -f $dir/stock-mtd1.bin ] || nanddump -q --bb=skipbad -f $dir/stock-mtd1.bin /dev/mtd1"
	echo "stock slot saved on the card: $(r1 "ls -l $dir/stock-mtd1.bin | awk '{print \$5}'") bytes"
else
	[ -x "$flasher" ] || { echo "no $flasher: run build.sh"; exit 1; }
	src=/tmp/r1-linux.uimage
	adb push "$img" "$src" >/dev/null
	adb push "$flasher" /tmp/r1flash >/dev/null
	r1 "chmod 755 /tmp/r1flash"
	# The whole slot as it is now, for going back to it:
	# r1flash write /dev/mtd1 flash-mtd1-prev.bin.
	r1 "/tmp/r1flash dump /dev/mtd1 $dir/flash-mtd1-prev.bin"
	echo "slot saved on the card as flash-mtd1-prev.bin"
fi
[ "$(r1 "md5sum $src | cut -d' ' -f1")" = "$md5" ] || { echo "the copy on the R1 differs"; exit 1; }

if [ $dry = 1 ]; then
	[ $system = mainline ] && r1 "rm -f $src /tmp/r1flash"
	echo "dry run: stopping before the erase"
	exit 0
fi
printf "Type flash to erase mtd1 and write the mainline kernel: "
read -r answer
[ "$answer" = flash ] || { echo "not written"; exit 1; }

if [ $system = stock ]; then
	r1 "flash_erase -q /dev/mtd1 0 0 && nandwrite -q -p -m /dev/mtd1 $src"
	back=$(r1 "nanddump -q --bb=skipbad -l $size /dev/mtd1 | head -c $size | md5sum | cut -d' ' -f1")
else
	r1 "/tmp/r1flash write /dev/mtd1 $src"
	back=$(r1 "head -c $size /dev/mtd1 | md5sum | cut -d' ' -f1")
	r1 "rm -f $src /tmp/r1flash"
fi
if [ "$back" != "$md5" ]; then
	echo "READ-BACK DIFFERS ($back): don't reboot. Volume Up with r1.upt on the card restores stock."
	exit 1
fi
echo "written and read back ($md5). Reboot the R1 to start the new flash kernel."
