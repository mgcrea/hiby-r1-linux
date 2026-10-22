#!/usr/bin/env bash
# Build an out-of-tree module for the R1's stock 4.4.94 kernel.
#   build.sh <module-dir>     (relative to this directory)
# The tree is configured to match the stock struct module layout (352
# bytes, init at 208, exit at 324) and vermagic, checked by layout.py.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
mod="${1:?module dir}"
docker run --rm --platform linux/amd64 -v "$here:/w" r1-stock-modules sh -euc '
  export ARCH=mips CROSS_COMPILE=mipsel-linux-gnu-
  if [ ! -f /w/.cache/.config ] || ! cmp -s /w/config.fragment /w/.cache/fragment; then
    make -s ci20_defconfig
    ./scripts/kconfig/merge_config.sh -m .config /w/config.fragment >/dev/null
    make -s olddefconfig
    mkdir -p /w/.cache && cp .config /w/.cache/.config && cp /w/config.fragment /w/.cache/fragment
  else
    cp /w/.cache/.config .config
  fi
  # gcc 12 is far newer than this tree expects.
  make -s modules_prepare HOSTCFLAGS="-O2 -fcommon -std=gnu89" KCFLAGS="-Wno-error" 2>&1 | grep -v -i warning || true
  make -s M=/w/'"$mod"' modules KCFLAGS="-Wno-error" 2>&1 | grep -v -i warning || true
'
