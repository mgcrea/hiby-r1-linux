#!/usr/bin/env python3
"""Build the R1's system image for the `rootfs` flash slot: the stock
programs mainline runs (adbd, dbus, BlueZ, bluez-alsa, wpa_supplicant), the
libraries they and the app need, the font and the AP6212's firmware
(Bluetooth and Wi-Fi), taken from the unpacked stock root filesystem, at the paths init expects under /rom.

    [R1_APP=APP] tools/mksystem.py [STOCK_ROOTFS [APP [OUT]]]

Defaults: ../firmware/stock/rootfs, $R1_APP (the build of the app init
starts from the card, only read for its libraries: the app itself stays on
the card; without one the image has only the stock programs' libraries) and
out/system.squashfs.
The image holds HiBy's files, so it stays in out/, untracked.
"""
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.join(HERE, "..", "..")

PROGRAMS = [
    "usr/bin/adbd",
    "usr/bin/dbus-daemon",
    "usr/libexec/bluetooth/bluetoothd",
    "usr/bin/bluealsa",
    "usr/bin/bluealsa-aplay",
    "usr/bin/bluealsa-cli",
    "usr/bin/bluetoothctl",
    "usr/bin/hciconfig",
    "usr/bin/hcitool",
    "usr/sbin/wpa_supplicant",
    "usr/sbin/wpa_cli",
]
# Loaded at run time, so absent from DT_NEEDED: libnss_files for dbus's user
# lookups, libgcc_s for pthread_cancel (bluealsa aborts without it when a
# stream ends), and the loader itself.
EXTRA = ["lib/ld.so.1", "lib/libnss_files.so.2", "lib/libgcc_s.so.1",
         "usr/resource/fonts/default.otf"]
# Each stock file and the name the kernel asks for. btbcm asks for
# brcm/BCM43430A1.hcd; stock's bt_init picks the file by the module's chip
# vendor, and this R1 takes the 1010.1030 one (docs/kernel.md, "Bluetooth").
# init copies it to /tmp/firmware. brcmfmac asks for the BCM43430A1's
# brcmfmac43430-sdio.bin and .txt (its settings: this module's nvram), which
# the kernel finds in /lib/firmware.
FIRMWARE = [
    ("lib/firmware/bt_bcm/BCM4343A1_001.002.009.1010.1030.hcd", "lib/firmware/brcm/BCM43430A1.hcd"),
    ("lib/firmware/wifi_bcm/fw_bcm43438a1.bin", "lib/firmware/brcm/brcmfmac43430-sdio.bin"),
    ("lib/firmware/wifi_bcm/nvram_ap6212a.txt", "lib/firmware/brcm/brcmfmac43430-sdio.txt"),
]
LIB_DIRS = ["lib", "usr/lib"]


def needed(path):
    """DT_NEEDED names of a 32-bit little-endian ELF file."""
    with open(path, "rb") as f:
        data = f.read()
    if data[:4] != b"\x7fELF" or data[4] != 1 or data[5] != 1:
        return []
    phoff, = struct.unpack_from("<I", data, 28)
    phentsize, phnum = struct.unpack_from("<HH", data, 42)
    loads, dynamic = [], None
    for i in range(phnum):
        p_type, p_offset, p_vaddr, _, p_filesz = struct.unpack_from("<5I", data, phoff + i * phentsize)
        if p_type == 1:
            loads.append((p_vaddr, p_offset, p_filesz))
        elif p_type == 2:
            dynamic = (p_offset, p_filesz)
    if not dynamic:
        return []

    def offset(vaddr):
        for v, o, n in loads:
            if v <= vaddr < v + n:
                return vaddr - v + o
        raise ValueError(f"{path}: address 0x{vaddr:x} outside the file")

    names, strtab = [], None
    for i in range(0, dynamic[1], 8):
        tag, val = struct.unpack_from("<iI", data, dynamic[0] + i)
        if tag == 0:
            break
        if tag == 1:
            names.append(val)
        elif tag == 5:
            strtab = offset(val)
    return [data[strtab + n:data.index(b"\0", strtab + n)].decode() for n in names]


def copy(root, rel, dest):
    """Copies rel, and what its symlinks point at, keeping the links."""
    src, dst = os.path.join(root, rel), os.path.join(dest, rel)
    if os.path.lexists(dst):
        return
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    if os.path.islink(src):
        target = os.readlink(src)
        os.symlink(target, dst)
        copy(root, os.path.normpath(os.path.join(os.path.dirname(rel), target)), dest)
    else:
        shutil.copy2(src, dst)


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else os.path.join(REPO, "firmware/stock/rootfs")
    player = sys.argv[2] if len(sys.argv) > 2 else os.environ.get("R1_APP")
    out = sys.argv[3] if len(sys.argv) > 3 else os.path.join(HERE, "../out/system.squashfs")
    if player and not os.path.isfile(player):
        sys.exit(f"{player}: no such app build")
    if not player:
        print("no app given (R1_APP): the image only has what the stock programs need")

    todo = [os.path.join(root, p) for p in PROGRAMS] + ([player] if player else [])
    files, seen = set(PROGRAMS + EXTRA), set()
    while todo:
        for name in needed(todo.pop()):
            if name in seen:
                continue
            seen.add(name)
            hit = [d for d in LIB_DIRS if os.path.lexists(os.path.join(root, d, name))]
            if not hit:
                sys.exit(f"{name}: not in the stock {' or '.join(LIB_DIRS)}")
            files.add(f"{hit[0]}/{name}")
            todo.append(os.path.realpath(os.path.join(root, hit[0], name)))

    with tempfile.TemporaryDirectory() as stage:
        for rel in sorted(files):
            copy(root, rel, stage)
        for src, dst in FIRMWARE:
            fw = os.path.join(stage, dst)
            os.makedirs(os.path.dirname(fw), exist_ok=True)
            shutil.copy2(os.path.join(root, src), fw)
        with open(os.path.join(stage, "etc-r1-system"), "w") as f:
            f.write(f"r1 system {time.strftime('%Y-%m-%d %H:%M')}\n" + "".join(f"{p}\n" for p in sorted(files)))
        os.makedirs(os.path.join(stage, "etc"), exist_ok=True)
        os.rename(os.path.join(stage, "etc-r1-system"), os.path.join(stage, "etc/r1-system"))
        if os.path.exists(out):
            os.remove(out)
        subprocess.run(["mksquashfs", stage, out, "-comp", "lzo", "-all-root", "-noappend",
                        "-no-xattrs", "-quiet"], check=True)
    print(f"{out}: {os.path.getsize(out)} bytes, {len(files)} files and {len(FIRMWARE)} firmware files")


if __name__ == "__main__":
    main()
