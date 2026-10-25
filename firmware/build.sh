#!/usr/bin/env bash
# Build the r1player firmware: stock rootfs plus overlay/ and patches/,
# repacked into out/r1player/r1.upt and checked against stock.
#   build.sh
# overlay/ holds the files the image adds, patches/ the changes to HiBy's
# own files (kept as diffs, since their files aren't ours to publish);
# patched/rootfs is rebuilt from scratch each time, so it never drifts from
# what git tracks.
set -euo pipefail
cd "$(dirname "$0")"

rm -rf patched/rootfs
mkdir -p patched out/r1player
cp -a stock/rootfs patched/rootfs
cp -R overlay/. patched/rootfs/
for p in patches/*.patch; do
	patch -s -p1 -d patched/rootfs < "$p"
done
./repack.sh stock patched/rootfs out/r1player/r1.upt
./verify.sh stock out/r1player/r1.upt
