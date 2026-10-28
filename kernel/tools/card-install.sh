#!/usr/bin/env bash
# Put the card kernel from build.sh on the R1's SD card, over ADB from
# mainline: out/r1-linux.bin and its entry point (/.r1-mainline/entry).
# /.r1-mainline/modules is the flash kernel's (flash-install.sh): this one
# has Wi-Fi built in. The flash kernel kexecs it at
# the next start; one that doesn't come up makes the next start stay on the
# flash kernel (docs/kernel.md, "Replacing stock in flash").
#
#   tools/card-install.sh [--reboot]
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
export ADB_LIBUSB=0
out="$here/../out"
bin="$out/r1-linux.bin"

[ -f "$bin" ] || { echo "no $bin: run build.sh"; exit 1; }
# System.map's addresses are sign-extended to 64 bits: the low 32.
entry=$(awk '$3 == "kernel_entry" { print substr($1, length($1) - 7) }' "$out/System.map")
[ ${#entry} = 8 ] || { echo "no kernel_entry in out/System.map"; exit 1; }
rel=$(cat "$out/release" 2>/dev/null)
[ -n "$rel" ] || { echo "no out/release: run build.sh"; exit 1; }
md5=$(md5 -q "$bin" 2>/dev/null || md5sum "$bin" | cut -d' ' -f1)

r1() { adb shell "$1" < /dev/null | tr -d '\r'; }
case "$(r1 'uname -r')" in
7.*) ;;
*) echo "the R1 isn't on mainline with ADB"; exit 1 ;;
esac
sd=/mnt/sd_0
dir=$sd/.r1-mainline
r1 "grep -q '^/dev/mmcblk0p1 $sd ' /proc/mounts && [ ! -e /tmp/sd-shared ]" ||
	{ echo "the SD card is not mounted on the R1 (shared with a computer?)"; exit 1; }

r1 "mount -o remount,rw $sd"
trap 'r1 "sync; mount -o remount,ro $sd" >/dev/null' EXIT
adb push "$bin" "$dir/r1-linux.bin" >/dev/null
r1 "echo 0x$entry > $dir/entry"
[ "$(r1 "md5sum $dir/r1-linux.bin | cut -d' ' -f1")" = "$md5" ] || { echo "the copy on the card differs"; exit 1; }
echo "on the card: r1-linux.bin ($md5, $rel), entry 0x$entry"
if [ "${1:-}" = --reboot ]; then
	r1 "sync; mount -o remount,ro $sd"
	trap - EXIT
	r1 "/sbin/r1-reboot" >/dev/null || true
	echo "restarting"
fi
