#!/usr/bin/env bash
# Check a repacked .upt against the stock unpacked update.
#   verify.sh <stock-dir> <file.upt>
# Extracts it, checks every md5 the updater checks, then diffs the rootfs
# listing (mode, owner, size, mtime, path) and file contents against stock.
set -euo pipefail

stock=$(realpath "$1")
upt=$(realpath "$2")
t="${upt%.upt}.verify"
[[ -d "$t" ]] && chmod -R u+w "$t" && rm -rf "$t"
mkdir -p "$t/iso"
bsdtar -xf "$upt" -C "$t/iso"
chmod -R u+w "$t/iso"
v="$t/iso/ota_v0"

for img in xImage rootfs.squashfs; do
    cat $(ls "$v/$img".[0-9][0-9][0-9][0-9].* | sort) > "$t/$img"
    whole=$(md5sum < "$t/$img" | cut -d' ' -f1)
    size=$(stat -c %s "$t/$img")
    grep -A3 "img_name=$img\$" "$v/ota_update.in" | grep -q "img_size=$size" || { echo "FAIL $img size $size not in ota_update.in"; exit 1; }
    grep -A3 "img_name=$img\$" "$v/ota_update.in" | grep -q "img_md5=$whole" || { echo "FAIL $img md5 $whole not in ota_update.in"; exit 1; }
    prev=$whole i=0
    for part in $(ls "$v/$img".[0-9][0-9][0-9][0-9].* | sort); do
        [[ "$part" == *".$prev" ]] || { echo "FAIL chunk name $part, expected suffix $prev"; exit 1; }
        sum=$(md5sum < "$part" | cut -d' ' -f1)
        i=$((i + 1))
        [[ "$(sed -n "${i}p" "$v/ota_md5_$img.$whole")" == "$sum" ]] || { echo "FAIL ota_md5 line $i for $part"; exit 1; }
        prev=$sum
    done
    echo "ok   $img: $size bytes, md5 $whole, $i chunks chained"
done

unsquashfs -s "$t/rootfs.squashfs" | grep -E 'Compression|Block size' | sed 's/^/     /'
unsquashfs -lln "$t/rootfs.squashfs" 2>/dev/null | tail -n +4 > "$t/rootfs.lln"
unsquashfs -lln "$stock/rootfs.squashfs" 2>/dev/null | tail -n +4 > "$t/stock.lln"
echo "--- listing diff vs stock (mode owner size mtime path):"
diff "$t/stock.lln" "$t/rootfs.lln" && echo "     (none)"
unsquashfs -q -no-xattrs -d "$t/rootfs" "$t/rootfs.squashfs" >/dev/null 2>&1
echo "--- content diff vs stock:"
diff -r --no-dereference -q "$stock/rootfs" "$t/rootfs" && echo "     (none)"
