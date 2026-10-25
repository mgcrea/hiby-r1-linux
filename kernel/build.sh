#!/usr/bin/env bash
# Build mainline Linux for the HiBy R1.
#
#   build.sh            reset the tree to upstream, apply patches/, build;
#                       writes out/r1-linux.bin (vmlinux.bin + DTB) and
#                       prints the load address and entry point for r1jump
#                       and out/r1-linux.uimage (the same kernel xz-compressed
#                       as a self-decompressing uImage, for the R1's flash
#                       kernel slot, which the stock boot loader loads)
#   build.sh patches    export the volume tree's commits back to patches/
#
# The tree lives in the r1-linux Docker volume (Linux needs a case-sensitive
# filesystem); patches/, r1.config and initramfs/ here are the source of
# truth. To change the kernel, commit in the volume tree on branch r1, then
# run `build.sh patches`.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
version=7.3
mkdir -p "$here/out"

docker run --rm -v r1-linux:/src -v "$here:/r1" r1-mainline sh -euc '
  version='"$version"'
  cd /src
  if [ ! -d linux-$version/.git ]; then
    curl -fsSL https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-$version.tar.xz | tar -xJ
    cd linux-$version
    git init -q && git add -A
    git -c user.name=r1 -c user.email=r1@local commit -qm "linux $version"
  fi
  cd /src/linux-$version
  base=$(git rev-list --max-parents=0 HEAD)
  # Re-applying the patches resets the timestamps of the patched files, and some
  # (asm/cpu.h, asm/bootinfo.h) are included nearly everywhere: only do it
  # when patches/ changed. The stamp lives in the tree it describes.
  stamp=.git/r1-patches.sha
  if [ "'"${1:-}"'" = patches ]; then
    rm -f /r1/patches/*.patch
    git format-patch -q -o /r1/patches $base..r1
    cat /r1/patches/*.patch | sha256sum > $stamp
    ls /r1/patches
    exit
  fi
  if ! cat /r1/patches/*.patch | sha256sum | cmp -s - $stamp; then
    echo "applying patches"
    git checkout -q -f -B r1 $base
    git -c user.name="Olivier Louvignes" -c user.email=olivier@mgcrea.io am -q /r1/patches/*.patch
    cat /r1/patches/*.patch | sha256sum > $stamp
  fi

  # Native arm64 build: /src/build held an amd64 (emulated) build.
  O=/src/build-arm64
  mk() { make -s O=$O ARCH=mips CROSS_COMPILE=mipsel-linux-gnu- "$@"; }
  mkdir -p $O
  if ! sha256sum /r1/r1.config | cut -d" " -f1 | cmp -s - $O/.r1-config.sha; then
    echo "configuring"
    mk cu1000-neo_defconfig
    scripts/kconfig/merge_config.sh -Q -O $O -m $O/.config /r1/r1.config >/dev/null
    mk olddefconfig
    sha256sum /r1/r1.config | cut -d" " -f1 > $O/.r1-config.sha
  fi
  # Fail if a requested option did not stick (missing dependency, typo).
  # A disabled option may be absent altogether, which is fine.
  grep -E "^CONFIG_[A-Z0-9_]+=" /r1/r1.config | while read -r line; do
    grep -qxF "$line" $O/.config || echo "warning: r1.config: $line did not stick"
  done
  grep -E "^# CONFIG_[A-Z0-9_]+ is not set$" /r1/r1.config | cut -d" " -f2 | while read -r opt; do
    ! grep -q "^$opt=" $O/.config || echo "warning: r1.config: $opt is still enabled"
  done
  # Test tools for the initramfs, built against tinyalsa (see Dockerfile).
  ta=/opt/tinyalsa
  mipsel-linux-gnu-gcc -static -Os -Wall -I$ta/include -o $O/r1tone /r1/initramfs/r1tone.c $ta/libtinyalsa.a -lm
  mipsel-linux-gnu-gcc -static -nostdlib -ffreestanding -mno-abicalls -fno-pic -no-pie -Os -Wall -Wl,--build-id=none -o $O/r1kexec /r1/initramfs/r1kexec.c
  # The flash writer flash-install.sh pushes to /tmp (not in the image).
  mipsel-linux-gnu-gcc -static -Os -Wall -o /r1/out/r1flash /r1/tools/r1flash.c
  # Through a log file: a pipe would hide make failing, and the last
  # image would be reported as new.
  status=0
  mk -j$(nproc) vmlinux.bin vmlinuz.bin dtbs > $O/make.log 2>&1 || status=$?
  grep -v -E "^\s*$" $O/make.log || true
  [ $status = 0 ] || { echo "make failed"; exit 1; }
  cat $O/arch/mips/boot/vmlinux.bin $O/arch/mips/boot/dts/ingenic/hiby-r1.dtb > /r1/out/r1-linux.bin
  cp $O/System.map /r1/out/System.map
  # The appended DTB must land exactly on __appended_dtb.
  dtb=$(grep " __appended_dtb$" $O/System.map | cut -c9-16)
  [ $((0x$dtb - 0x80100000)) = $(stat -c %s $O/arch/mips/boot/vmlinux.bin) ] || { echo "DTB offset mismatch"; exit 1; }
  load=$(mipsel-linux-gnu-readelf -l $O/vmlinux | awk "/LOAD/ {print \$3; exit}")
  entry=$(mipsel-linux-gnu-readelf -h $O/vmlinux | awk "/Entry point/ {print \$4}")
  echo "out/r1-linux.bin: $(stat -c %s /r1/out/r1-linux.bin) bytes, load $load, entry $entry"

  # The flash image: the decompressor (vmlinuz) with the DTB after it, where
  # it looks for one (by its magic; vmlinuz is stripped, so the offset cannot
  # be checked here) and moves it behind the kernel it unpacks, in a legacy
  # uImage header: the stock SPL loads it by the header (load address,
  # entry, size; it checks no CRC) into memory and jumps to it.
  z=$O/vmlinuz
  zload=$(mipsel-linux-gnu-readelf -l $z | awk "/LOAD/ {print \$3; exit}")
  zentry=$(mipsel-linux-gnu-readelf -h $z | awk "/Entry point/ {print \$4}")
  cat $O/arch/mips/boot/vmlinuz.bin $O/arch/mips/boot/dts/ingenic/hiby-r1.dtb > $O/vmlinuz-dtb.bin
  # The decompressor copies the DTB to __appended_dtb in the kernel: it must
  # end below the decompressor, which is still running.
  dtbsize=$(stat -c %s $O/arch/mips/boot/dts/ingenic/hiby-r1.dtb)
  [ $((0x$dtb + dtbsize)) -le $((zload)) ] || { echo "the DTB copy would overwrite the decompressor"; exit 1; }
  python3 /r1/tools/mkuimage.py $zload $zentry "Linux-$version r1" $O/vmlinuz-dtb.bin /r1/out/r1-linux.uimage
  # The kernel slot (mtd1) is 5 MiB.
  size=$(stat -c %s /r1/out/r1-linux.uimage)
  [ $size -le 5242880 ] || { echo "out/r1-linux.uimage: $size bytes, over the 5 MiB kernel slot"; exit 1; }
  echo "out/r1-linux.uimage: $size bytes of 5242880, load $zload, entry $zentry"
' sh "${1:-}"
