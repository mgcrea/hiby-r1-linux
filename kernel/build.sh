#!/usr/bin/env bash
# Build mainline Linux for the HiBy R1.
#
#   build.sh            reset the tree to upstream, apply patches/, build
#                       the two kernels: out/r1-linux.uimage, the flash
#                       kernel (r1.config), xz-compressed as a
#                       self-decompressing uImage for the R1's kernel slot,
#                       which the stock boot loader loads, with its
#                       Wi-Fi modules in out/flash-modules; and
#                       out/r1-linux.bin, the card kernel (r1.config and
#                       r1-card.config: Wi-Fi), vmlinux.bin with the DTB,
#                       which the flash kernel kexecs (and r1jump can load),
#                       with its System.map and release
#   build.sh patches    export the volume tree's commits back to patches/
#
# The tree lives in the r1-linux Docker volume (Linux needs a case-sensitive
# filesystem); patches/, r1.config, r1-card.config and initramfs/ here are the source of
# truth. To change the kernel, commit in the volume tree on branch r1, then
# run `build.sh patches`.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
version=7.3
mkdir -p "$here/out"

# Everything below runs as one single-quoted sh -c script: an apostrophe in
# it, comments included, ends the script there.
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

  # Native arm64 builds (/src/build held an amd64, emulated, one): the
  # flash kernel in build-arm64 (r1.config), the card kernel in build-card
  # (r1.config, then r1-card.config: Wi-Fi), from the same tree.
  FLASH=/src/build-arm64
  CARD=/src/build-card
  mk() { make -s O=$O ARCH=mips CROSS_COMPILE=mipsel-linux-gnu- "$@"; }
  # configure DIR FRAGMENT...: merges the fragments into cu1000-neo_defconfig
  # when they changed, then warns about an option that did not stick (a
  # missing dependency, a typo), going by the last fragment that names it.
  # A disabled option may be absent altogether, which is fine.
  configure() {
    O=$1; shift
    mkdir -p $O
    sum=$(cat "$@" | sha256sum | cut -d" " -f1)
    if [ "$sum" != "$(cat $O/.r1-config.sha 2>/dev/null)" ]; then
      echo "configuring $(basename $O)"
      mk cu1000-neo_defconfig
      scripts/kconfig/merge_config.sh -Q -O $O -m $O/.config "$@" >/dev/null
      mk olddefconfig
      echo $sum > $O/.r1-config.sha
    fi
    cat "$@" | awk "/^CONFIG_|^# CONFIG_/ { o = \$1 == \"#\" ? \$2 : \$1; sub(/=.*/, \"\", o); last[o] = \$0 } END { for (o in last) print last[o] }" |
      while read -r line; do
        case "$line" in
        "# "*) opt=${line#\# }; opt=${opt%% *}
          ! grep -q "^$opt=" $O/.config || echo "warning: $(basename $O): $opt is still enabled" ;;
        *) grep -qxF "$line" $O/.config || echo "warning: $(basename $O): $line did not stick" ;;
        esac
      done
  }
  # make TARGET... in $O, through a log file: a pipe would hide make
  # failing, and the last image would be reported as new.
  build() {
    status=0
    mk -j$(nproc) "$@" > $O/make.log 2>&1 || status=$?
    grep -v -E "^\s*$" $O/make.log || true
    [ $status = 0 ] || { echo "make failed in $(basename $O)"; exit 1; }
  }
  # The appended DTB must land exactly on __appended_dtb.
  check_dtb() {
    dtb=$(grep " __appended_dtb$" $O/System.map | cut -c9-16)
    [ $((0x$dtb - 0x80100000)) = $(stat -c %s $O/arch/mips/boot/vmlinux.bin) ] || { echo "DTB offset mismatch in $(basename $O)"; exit 1; }
  }

  configure $FLASH /r1/r1.config
  # Test tools for the initramfs (which both kernels share), built against
  # tinyalsa (see Dockerfile); initramfs/list takes them from build-arm64.
  ta=/opt/tinyalsa
  mipsel-linux-gnu-gcc -static -Os -Wall -I$ta/include -o $FLASH/r1tone /r1/initramfs/r1tone.c $ta/libtinyalsa.a -lm
  mipsel-linux-gnu-gcc -static -nostdlib -ffreestanding -mno-abicalls -fno-pic -no-pie -Os -Wall -Wl,--build-id=none -o $FLASH/r1kexec /r1/initramfs/r1kexec.c
  # The flash writer flash-install.sh pushes to /tmp (not in the image).
  mipsel-linux-gnu-gcc -static -Os -Wall -o /r1/out/r1flash /r1/tools/r1flash.c
  build vmlinux.bin vmlinuz.bin dtbs modules
  check_dtb

  # The flash image: the decompressor (vmlinuz) with the DTB after it, where
  # it looks for one (by its magic; vmlinuz is stripped, so the offset cannot
  # be checked here) and moves it behind the kernel it unpacks, in a legacy
  # uImage header: the stock SPL loads it by the header (load address,
  # entry, size; it checks no CRC) into memory and jumps to it.
  dtbf=$O/arch/mips/boot/dts/ingenic/hiby-r1.dtb
  z=$O/vmlinuz
  zload=$(mipsel-linux-gnu-readelf -l $z | awk "/LOAD/ {print \$3; exit}")
  zentry=$(mipsel-linux-gnu-readelf -h $z | awk "/Entry point/ {print \$4}")
  cat $O/arch/mips/boot/vmlinuz.bin $dtbf > $O/vmlinuz-dtb.bin
  # The decompressor copies the DTB to __appended_dtb in the kernel: it must
  # end below the decompressor, which is still running.
  dtbsize=$(stat -c %s $dtbf)
  [ $((0x$dtb + dtbsize)) -le $((zload)) ] || { echo "the DTB copy would overwrite the decompressor"; exit 1; }
  python3 /r1/tools/mkuimage.py $zload $zentry "Linux-$version r1" $O/vmlinuz-dtb.bin /r1/out/r1-linux.uimage
  # The kernel slot (mtd1) is 5 MiB.
  size=$(stat -c %s /r1/out/r1-linux.uimage)
  [ $size -le 5242880 ] || { echo "out/r1-linux.uimage: $size bytes, over the 5 MiB kernel slot"; exit 1; }
  echo "out/r1-linux.uimage: $size bytes of 5242880, load $zload, entry $zentry"
  # Its Wi-Fi modules, in the order r1-wifi loads them: they load only
  # into this build (TRIM_UNUSED_KSYMS), so flash-install.sh puts them on
  # the card under its release. brcmfmac asks for its vendor module
  # (brcmfmac-cyw for the BCM43430) when it attaches, and finds it loaded.
  release=$(cat $O/include/config/kernel.release)
  rm -rf /r1/out/flash-modules
  mkdir -p /r1/out/flash-modules/$release
  for m in net/wireless/cfg80211 drivers/net/wireless/broadcom/brcm80211/brcmutil/brcmutil drivers/net/wireless/broadcom/brcm80211/brcmfmac/brcmfmac drivers/net/wireless/broadcom/brcm80211/brcmfmac/cyw/brcmfmac-cyw; do
    mipsel-linux-gnu-strip --strip-debug -o /r1/out/flash-modules/$release/${m##*/}.ko $O/$m.ko
  done
  echo "out/flash-modules/$release: $(du -sk /r1/out/flash-modules/$release | cut -f1) KB"

  # The card kernel, which the flash one kexecs: vmlinux.bin with the DTB.
  configure $CARD /r1/r1.config /r1/r1-card.config
  build vmlinux.bin dtbs
  check_dtb
  cat $O/arch/mips/boot/vmlinux.bin $O/arch/mips/boot/dts/ingenic/hiby-r1.dtb > /r1/out/r1-linux.bin
  cp $O/System.map /r1/out/System.map
  cp $O/include/config/kernel.release /r1/out/release
  rm -rf /r1/out/modules
  load=$(mipsel-linux-gnu-readelf -l $O/vmlinux | awk "/LOAD/ {print \$3; exit}")
  entry=$(mipsel-linux-gnu-readelf -h $O/vmlinux | awk "/Entry point/ {print \$4}")
  echo "out/r1-linux.bin: $(stat -c %s /r1/out/r1-linux.bin) bytes, load $load, entry $entry"
' sh "${1:-}"
