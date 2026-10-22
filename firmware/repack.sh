#!/usr/bin/env bash
# Rebuild a HiBy R1 .upt from an unpacked stock update and a rootfs tree.
#
#   repack.sh <stock-dir> <rootfs-dir | rootfs.squashfs> <out.upt>
#
# <stock-dir> holds iso/ (the stock .upt extracted) and rootfs.squashfs.
# Passing a .squashfs instead of a tree skips mksquashfs, which lets the
# chunking be checked against stock byte for byte.
#
# Kernel chunks, ota_config.in and ota_v0.ok are copied from stock unchanged.
# unsquashfs run as a normal user drops owners and setuid bits, so every
# entry's mode/uid/gid is restored from the stock image's listing.
# Local throwaway tooling: assumes GNU coreutils and Homebrew squashfs/cdrtools.
set -euo pipefail

stock=$(realpath "$1")
src=$(realpath "$2")
out=$(realpath -m "$3")
work="${out%.upt}.contents"
chunk=512k

rm -rf "$work" "$out"
mkdir -p "$work/ota_v0"
cp "$stock/iso/ota_config.in" "$work/"
cp "$stock/iso/ota_v0/ota_v0.ok" "$stock"/iso/ota_v0/xImage.* "$stock"/iso/ota_v0/ota_md5_xImage.* "$work/ota_v0/"
chmod u+w "$work"/ota_v0/* "$work/ota_config.in"

if [[ -d "$src" ]]; then
    pseudo="$work.pseudo"
    unsquashfs -lln "$stock/rootfs.squashfs" 2>/dev/null | python3 -I -c '
import os, stat, sys
seen = set()
for line in sys.stdin:
    f = line.split(None, 5)
    if len(f) < 6 or not f[5].startswith("squashfs-root/"):
        continue
    perm, (uid, gid), path = f[0], f[1].split("/"), f[5].rstrip("\n")
    path = path[len("squashfs-root"):].split(" -> ")[0]
    seen.add(path)
    # Octal from the rwx triplets, plus setuid/setgid/sticky.
    mode = 0
    for i in range(3):
        t = perm[1 + i * 3 : 4 + i * 3]
        mode = mode * 8 + (4 if t[0] == "r" else 0) + (2 if t[1] == "w" else 0) + (1 if t[2] in "xst" else 0)
    mode |= (0o4000 if perm[3] in "sS" else 0) | (0o2000 if perm[6] in "sS" else 0) | (0o1000 if perm[9] in "tT" else 0)
    print(f"\"{path}\" m {mode:o} {uid} {gid}")
# Files added by a patch: keep their mode, owned by root.
root = sys.argv[1]
for d, dirs, files in os.walk(root):
    for name in dirs + files:
        full = os.path.join(d, name)
        path = full[len(root):]
        if path not in seen:
            mode = 0o777 if os.path.islink(full) else stat.S_IMODE(os.lstat(full).st_mode)
            print(f"\"{path}\" m {mode:o} 0 0")
' "$src" > "$pseudo"
    mksquashfs "$src" "$work/rootfs.squashfs" -comp lzo -b 131072 -noappend -no-xattrs \
        -root-mode 755 -root-uid 0 -root-gid 0 -pf "$pseudo" -quiet -no-progress
    rootfs="$work/rootfs.squashfs"
else
    rootfs="$src"
fi

# Each chunk is named after the md5 of the chunk before it (the first after
# the whole image's md5); ota_md5_* lists every chunk's own md5 in order.
(
    cd "$work/ota_v0"
    split -b "$chunk" --numeric-suffixes=0 -a 4 "$rootfs" rootfs.squashfs.
    whole=$(md5sum < "$rootfs" | cut -d' ' -f1)
    prev=$whole
    : > "ota_md5_rootfs.squashfs.$whole"
    for part in $(ls rootfs.squashfs.[0-9][0-9][0-9][0-9] | sort); do
        sum=$(md5sum < "$part" | cut -d' ' -f1)
        echo "$sum" >> "ota_md5_rootfs.squashfs.$whole"
        mv "$part" "$part.$prev"
        prev=$sum
    done
    size=$(stat -c %s "$rootfs")
    sed -E "/img_name=rootfs.squashfs/,/img_md5=/{s/^img_size=.*/img_size=$size/;s/^img_md5=.*/img_md5=$whole/}" \
        "$stock/iso/ota_v0/ota_update.in" > ota_update.in
)
rm -f "$work/rootfs.squashfs"

mkisofs -quiet -V CDROM -f -U -J -joliet-long -r -allow-lowercase -allow-multidot \
    -input-charset utf-8 -o "$out" "$work"
echo "wrote $out"
