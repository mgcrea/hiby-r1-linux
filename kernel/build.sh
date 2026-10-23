#!/usr/bin/env bash
# Build mainline Linux for the HiBy R1.
#
#   build.sh            reset the tree to upstream, apply patches/, build;
#                       writes out/r1-linux.bin (vmlinux.bin + DTB) and
#                       prints the load address and entry point for r1jump
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

docker run --rm --platform linux/amd64 -v r1-linux:/src -v "$here:/r1" r1-mainline sh -euc '
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
  if [ "'"${1:-}"'" = patches ]; then
    rm -f /r1/patches/*.patch
    git format-patch -q -o /r1/patches $base..r1
    ls /r1/patches
    exit
  fi
  git checkout -q -f -B r1 $base
  git -c user.name="Olivier Louvignes" -c user.email=olivier@mgcrea.io am -q /r1/patches/*.patch

  O=/src/build
  mk() { make -s O=$O ARCH=mips CROSS_COMPILE=mipsel-linux-gnu- "$@"; }
  mkdir -p $O
  mk cu1000-neo_defconfig
  scripts/kconfig/merge_config.sh -Q -O $O -m $O/.config /r1/r1.config >/dev/null
  mk olddefconfig
  # Fail if a requested option did not stick (missing dependency, typo).
  # A disabled option may be absent altogether, which is fine.
  grep -E "^CONFIG_[A-Z0-9_]+=" /r1/r1.config | while read -r line; do
    grep -qxF "$line" $O/.config || echo "warning: r1.config: $line did not stick"
  done
  grep -E "^# CONFIG_[A-Z0-9_]+ is not set$" /r1/r1.config | cut -d" " -f2 | while read -r opt; do
    ! grep -q "^$opt=" $O/.config || echo "warning: r1.config: $opt is still enabled"
  done
  mk -j$(nproc) vmlinux.bin dtbs 2>&1 | grep -v -E "^\s*$" || true
  test -f $O/arch/mips/boot/vmlinux.bin
  cat $O/arch/mips/boot/vmlinux.bin $O/arch/mips/boot/dts/ingenic/hiby-r1.dtb > /r1/out/r1-linux.bin
  cp $O/System.map /r1/out/System.map
  load=$(mipsel-linux-gnu-readelf -l $O/vmlinux | awk "/LOAD/ {print \$3; exit}")
  entry=$(mipsel-linux-gnu-readelf -h $O/vmlinux | awk "/Entry point/ {print \$4}")
  echo "out/r1-linux.bin: $(stat -c %s /r1/out/r1-linux.bin) bytes, load $load, entry $entry"
' sh "${1:-}"
