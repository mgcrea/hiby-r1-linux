#!/usr/bin/env bash
# Does the R1's RAM survive a reset and the stock boot that follows?
#
#   ramtest.sh mark    fill ~4 MB of tmpfs with tagged pages, then dump RAM
#   ramtest.sh check   (after a reboot) dump RAM again and report survivors
#
# Each 4 KiB page of the marker file starts with "R1RAMTAG", a per-run
# session id and the page index, so a RAM dump shows exactly which physical
# pages held marker data before and after the reset.
set -euo pipefail
export ADB_LIBUSB=0
dir="$(cd "$(dirname "$0")" && pwd)/../out/ramtest"
mkdir -p "$dir"

dump() {
  # 64 MiB of physical RAM through /dev/mem (the stock kernel allows it).
  # The R1's adbd predates exec-out and runs shell commands on a pty, so the
  # bytes go through base64. Nothing is staged in /tmp, which would overwrite
  # the free RAM being measured. About 2 minutes, so progress goes per 8 MiB.
  : > "$1"
  for mib in 0 8 16 24 32 40 48 56; do
    printf 'dumping MiB %2d..%2d\r' "$mib" "$((mib + 8))" >&2
    adb shell "dd if=/dev/mem bs=1048576 skip=$mib count=8 2>/dev/null | gzip -1 | base64" \
      | tr -d '\r' | base64 -d | gunzip >> "$1"
  done
  echo "dumped $(stat -c %s "$1") bytes to $1"
}

case "${1:-}" in
  mark)
    session=$(head -c 4 /dev/urandom | xxd -p)
    echo "$session" > "$dir/session"
    # 1024 pages; busybox has printf and dd, so build the file on the Mac.
    python3 -I - "$session" "$dir/marker.bin" <<'EOF'
import struct, sys
session, out = bytes.fromhex(sys.argv[1]), sys.argv[2]
with open(out, "wb") as f:
    for i in range(1024):
        head = b"R1RAMTAG" + session + struct.pack("<I", i)
        f.write((head * (4096 // len(head) + 1))[:4096])
EOF
    adb push "$dir/marker.bin" /tmp/r1ramtag.bin >/dev/null
    dump "$dir/before.bin"
    ;;
  check)
    dump "$dir/after.bin"
    python3 -I - "$(cat "$dir/session")" "$dir/before.bin" "$dir/after.bin" <<'EOF'
import sys
session = bytes.fromhex(sys.argv[1])
def pages(path):
    d = open(path, "rb").read()
    found = {}
    for off in range(0, len(d), 4096):
        if d[off:off + 8] == b"R1RAMTAG" and d[off + 8:off + 12] == session:
            found[off] = d[off:off + 4096]
    return found
before, after = pages(sys.argv[2]), pages(sys.argv[3])
intact = [a for a in before if after.get(a) == before[a]]
print(f"marker pages before reset: {len(before)}, intact after: {len(intact)}")
if before:
    lo, hi = min(before), max(before)
    print(f"marker pages spanned 0x{lo:08x}..0x{hi + 4096:08x}")
runs, start, prev = [], None, None
for a in sorted(intact):
    if start is None or a != prev + 4096:
        if start is not None:
            runs.append((start, prev + 4096))
        start = a
    prev = a
if start is not None:
    runs.append((start, prev + 4096))
for s, e in runs[:40]:
    print(f"  intact 0x{s:08x}..0x{e:08x} ({(e - s) // 1024} KiB)")
# Coarse map: how much of each MiB changed at all across the reset.
b, a = open(sys.argv[2], "rb").read(), open(sys.argv[3], "rb").read()
print("MiB: % of 4 KiB pages unchanged")
row = []
for mib in range(64):
    same = sum(b[o:o + 4096] == a[o:o + 4096] for o in range(mib << 20, (mib + 1) << 20, 4096))
    row.append(f"{mib:2d}:{same * 100 // 256:3d}")
for i in range(0, 64, 8):
    print("  " + "  ".join(row[i:i + 8]))
EOF
    ;;
  *) echo "usage: $0 mark|check" >&2; exit 2 ;;
esac
