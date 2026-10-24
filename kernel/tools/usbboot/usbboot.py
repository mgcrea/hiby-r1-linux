#!/usr/bin/env python3
"""Boot a kernel on the HiBy R1 from the X1600 boot ROM's USB mode, RAM only.

  uv run --with pyusb python tools/usbboot/usbboot.py out/usbboot/usbstage1.bin \
      out/usbboot/stage2.bin out/r1-linux.bin --entry 0x$(grep " kernel_entry$" out/System.map | cut -c9-16) \
      --apcr 0x02E049CD --epcr 0x019051CD --ccr 0x9A094410 [--wdt 20]   # stock clocks

Build the stages first (tools/usbboot/build.sh). Reach the boot ROM without Next:
  adb shell "devmem 0x100000cc 32 0x42575302; sync; reboot -f"
  uv run --with pyusb python tools/usbboot/usbboot.py --probe      # just talk to the boot ROM

Protocol as Rockbox's jztool (utils/jztool/src/usb.c, x1600.c): vendor
requests 0 GET_CPU_INFO, 1 SET_DATA_ADDRESS, 2 SET_DATA_LENGTH,
3 FLUSH_CACHES, 4 PROGRAM_START1, 5 PROGRAM_START2, the argument split over
wValue (high half) and wIndex (low half); data over bulk EP 1.
"""
import argparse
import os
import struct
import sys
import time

import usb.core
import usb.backend.libusb1

VID, PID = 0xA108, 0xEAEF
STAGE1_ADDR = 0x8000A000
STAGE1_RESULT = 0x8000F000
STAGE1_MAGIC = 0xC0DEF00D
STAGE2_ADDR = 0x8000A000
PARAMS_OFF = 8
CHUNK = 256 * 1024


def backend():
    for p in ("/opt/homebrew/lib/libusb-1.0.0.dylib", "/usr/local/lib/libusb-1.0.0.dylib"):
        if os.path.exists(p):
            return usb.backend.libusb1.get_backend(find_library=lambda _: p)
    return None


class BootRom:
    def __init__(self):
        self.dev = usb.core.find(idVendor=VID, idProduct=PID, backend=backend())
        if self.dev is None:
            sys.exit("no Ingenic USB boot device (a108:eaef): is the R1 in USB boot mode?")
        try:
            self.dev.set_configuration()
        except usb.core.USBError:
            pass

    def req(self, r, arg=0):
        self.dev.ctrl_transfer(0x40, r, arg >> 16, arg & 0xFFFF, None, 1000)

    def cpu_info(self):
        return bytes(self.dev.ctrl_transfer(0xC0, 0, 0, 0, 8, 1000)).rstrip(b"\0").decode()

    def send(self, addr, data):
        for off in range(0, len(data), CHUNK):
            part = data[off:off + CHUNK]
            self.req(1, addr + off)
            self.req(2, len(part))
            n = self.dev.write(0x01, part, 10000)
            if n != len(part):
                sys.exit(f"short write at 0x{addr + off:08x}: {n} of {len(part)}")

    def recv(self, addr, n):
        self.req(1, addr)
        self.req(2, n)
        return bytes(self.dev.read(0x81, n, 10000))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("stage1", nargs="?")
    ap.add_argument("stage2", nargs="?")
    ap.add_argument("kernel", nargs="?")
    ap.add_argument("--probe", action="store_true")
    ap.add_argument("--load", type=lambda s: int(s, 0), default=0x80100000)
    ap.add_argument("--entry", type=lambda s: int(s, 0))
    ap.add_argument("--apcr", type=lambda s: int(s, 0), default=0)
    ap.add_argument("--epcr", type=lambda s: int(s, 0), default=0)
    ap.add_argument("--ccr", type=lambda s: int(s, 0), default=0)
    ap.add_argument("--wdt", type=int, default=20, help="watchdog seconds, 0 for none")
    a = ap.parse_args()

    rom = BootRom()
    print("boot ROM:", rom.cpu_info())
    if a.probe:
        return

    stage1 = open(a.stage1, "rb").read()
    stage2 = bytearray(open(a.stage2, "rb").read())
    kernel = open(a.kernel, "rb").read()
    if struct.unpack_from("<I", stage2, PARAMS_OFF)[0] != 0x54423152:
        sys.exit("stage2 has no parameter block")
    # 45.8 watchdog ticks a second (EXCLK / 512 / 1024), docs/kernel.md.
    ticks = min(int(a.wdt * 45.8), 0xFFFF)
    struct.pack_into("<11I", stage2, PARAMS_OFF + 4, a.entry, 0, 0, 0, 0,
                     a.apcr, 0, a.epcr, a.ccr, ticks, 0)

    rom.req(3)
    rom.send(STAGE1_ADDR, stage1)
    rom.req(4, STAGE1_ADDR)
    time.sleep(0.5)
    res = struct.unpack("<14I", rom.recv(STAGE1_RESULT, 56))
    print("stage1: magic 0x%08x rc %d step %d err %d cpspr 0x%08x" %
          (res[0], res[1], res[3], res[4], res[13]))
    if res[0] != STAGE1_MAGIC or res[1] != 0:
        sys.exit("DDR init failed: " + " ".join("%08x" % r for r in res))

    t = time.time()
    rom.send(a.load, kernel)
    print("kernel: %d bytes to 0x%08x in %.1f s" % (len(kernel), a.load, time.time() - t))
    back = rom.recv(a.load, 4096)
    if back != kernel[:4096]:
        sys.exit("kernel read-back differs: DDR not usable")
    rom.send(STAGE2_ADDR, bytes(stage2))
    rom.req(3)
    print("starting stage2, entry 0x%08x, watchdog %d s" % (a.entry, a.wdt))
    try:
        rom.req(5, STAGE2_ADDR)
    except usb.core.USBError as e:
        print("(START2 reported", e, "- normal if the device left)")


if __name__ == "__main__":
    main()
