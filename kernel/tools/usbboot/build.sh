#!/bin/sh
# Build the two USB-boot stages into kernel/out/usbboot/ (in the r1-mainline
# image): Rockbox's usbstage1 for the R1, which sets up the LPDDR2 and
# returns to the boot ROM, and stage2 (stage2.c), which sets the clocks and
# jumps to the kernel. usbstage1 isn't merged in Rockbox yet: it is Gerrit
# change 7734, patchset 26 (2026-10-23). docs/kernel.md, "USB boot mode".
#
#   tools/usbboot/build.sh
set -e
here="$(cd "$(dirname "$0")" && pwd)"
out="$here/../../out/usbboot"
mkdir -p "$out"
[ -d "$out/rockbox" ] || {
	git clone -q https://github.com/Rockbox/rockbox.git "$out/rockbox"
	git -C "$out/rockbox" fetch -q https://gerrit.rockbox.org/r/rockbox refs/changes/34/7734/26
	git -C "$out/rockbox" checkout -q FETCH_HEAD
	# Debian's binutils name the format elf32-tradlittlemips.
	sed -i.orig 's/"elf32-littlemips"/"elf32-tradlittlemips"/' \
		"$out/rockbox"/firmware/target/mips/ingenic_x1600/*.lds
}
docker run --rm -v "$here":/t -v "$out":/u r1-mainline sh -euc '
sh /t/mkwrap.sh
export PATH=/xbin:$PATH
mkdir -p /u/build && cd /u/build
[ -f Makefile ] || /u/rockbox/tools/configure --target=304 --type=b >/dev/null
make -j8 usbstage1 >/dev/null
cp usbstage1.bin /u/
cd /t
CC="mipsel-linux-gnu-gcc -march=mips32r2 -EL -mno-abicalls -fno-pic -no-pie -msoft-float -ffreestanding -nostdlib -Os -G0 -Wall"
$CC -c start.S -o /u/start.o
$CC -c stage2.c -o /u/stage2.o
$CC -Wl,--build-id=none -Wl,-e,_start -Wl,--section-start=.text=0x8000a000 /u/start.o /u/stage2.o -o /u/stage2.elf
mipsel-linux-gnu-objcopy -O binary -j .text /u/stage2.elf /u/stage2.bin
ls -l /u/usbstage1.bin /u/stage2.bin'
