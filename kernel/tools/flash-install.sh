#!/usr/bin/env bash
# Write the mainline flash kernel (out/r1-linux.uimage) into the R1's
# `kernel` slot (mtd1), from the stock system over ADB. The stock SPL then
# boots it at every start; its r1-loader hands over to the kernel on the
# card (/.r1-mainline/r1-linux.bin) by kexec, and falls back to itself when
# that one failed to come up. Run it only with the user's go: it is the
# step that replaces stock (docs/kernel.md, "Replacing stock in flash").
#
#   tools/flash-install.sh [--dry-run]
#
# --dry-run does everything but the erase and the write. The way back:
# Volume Up held while the R1 starts, with a stock or auto-jump r1.upt at
# the card root, rewrites `kernel` and `rootfs` from it (the recovery in
# `kernel2`/`rootfs2`, which this leaves alone, as `uboot` and `ota`).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
export ADB_LIBUSB=0
img="$here/../out/r1-linux.uimage"
dry=0
[ "${1:-}" = --dry-run ] && dry=1

[ -f "$img" ] || { echo "no $img: run build.sh"; exit 1; }
size=$(wc -c < "$img" | tr -d " ")
[ "$size" -le 5242880 ] || { echo "the image is $size bytes, over the 5 MiB slot"; exit 1; }
[ "$(head -c 4 "$img" | od -An -tx1 | tr -d ' \n')" = 27051956 ] || { echo "not a uImage"; exit 1; }
md5=$(md5 -q "$img" 2>/dev/null || md5sum "$img" | cut -d' ' -f1)

r1() { adb shell "$1" | tr -d '\r'; }
[ "$(r1 'uname -r')" = 4.4.94+ ] || { echo "the R1 isn't on stock (with ADB): r1-reboot twice from mainline"; exit 1; }
[ "$(r1 "grep '^mtd1:' /proc/mtd")" = 'mtd1: 00500000 00020000 "kernel"' ] || { echo "unexpected mtd1:"; r1 'cat /proc/mtd'; exit 1; }
sd=$(r1 "grep '^/dev/mmcblk0p1 ' /proc/mounts | cut -d' ' -f2")
[ -n "$sd" ] || { echo "the SD card is not mounted on the R1"; exit 1; }
dir=$sd/.r1-mainline

echo "slot now: $(r1 'head -c 64 /dev/mtd1 | tail -c 32 | tr -d "\000"')"
echo "image:    $(head -c 64 "$img" | tail -c 32 | tr -d '\000'), $size bytes, md5 $md5"

# The image and a copy of the stock slot go to the card (stock's /tmp is
# RAM, with about 15 MB free).
r1 "mount -o remount,rw $sd"
trap 'r1 "sync; mount -o remount,ro $sd" >/dev/null' EXIT
adb push "$img" "$dir/r1-linux.uimage" >/dev/null
[ "$(r1 "md5sum $dir/r1-linux.uimage | cut -d' ' -f1")" = "$md5" ] || { echo "the copy on the card differs"; exit 1; }
r1 "[ -f $dir/stock-mtd1.bin ] || nanddump -q --bb=skipbad -f $dir/stock-mtd1.bin /dev/mtd1"
echo "stock slot saved on the card: $(r1 "ls -l $dir/stock-mtd1.bin | awk '{print \$5}'") bytes"

if [ $dry = 1 ]; then
	echo "dry run: stopping before the erase"
	exit 0
fi
printf "Type flash to erase mtd1 and write the mainline kernel: "
read -r answer
[ "$answer" = flash ] || { echo "not written"; exit 1; }

r1 "flash_erase -q /dev/mtd1 0 0 && nandwrite -q -p -m /dev/mtd1 $dir/r1-linux.uimage"
back=$(r1 "nanddump -q --bb=skipbad -l $size /dev/mtd1 | head -c $size | md5sum | cut -d' ' -f1")
if [ "$back" != "$md5" ]; then
	echo "READ-BACK DIFFERS ($back): don't reboot. Volume Up with r1.upt on the card restores stock."
	exit 1
fi
echo "written and read back ($md5). Reboot the R1 to start mainline from flash."
