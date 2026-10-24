#!/usr/bin/env python3
"""Wrap an image in a legacy U-Boot uImage header (no compression).

  mkuimage.py LOAD ENTRY NAME IN OUT

The R1's stock SPL loads a kernel by this header: the image goes to LOAD
and it jumps to ENTRY. Written here since the build image has no mkimage.
"""
import struct
import sys
import time
import zlib

load, entry, name, src, dst = sys.argv[1:6]
data = open(src, "rb").read()
fields = [0x27051956, 0, int(time.time()), len(data), int(load, 16), int(entry, 16),
          zlib.crc32(data), 5, 5, 2, 0, name.encode()[:32]]  # Linux, MIPS, kernel, none
fmt = ">7I4B32s"
fields[1] = zlib.crc32(struct.pack(fmt, *fields))
open(dst, "wb").write(struct.pack(fmt, *fields) + data)
