#!/usr/bin/env bash
# Builds fbpaint.bin (raw payload for r1jump, linked at 0x80010000) and
# fbinfo (static, runs on the R1) in the stock-modules Docker image.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
docker run --rm --platform linux/amd64 -v "$here:/w" -w /w r1-stock-modules sh -euc '
  cc=mipsel-linux-gnu-gcc
  $cc -march=mips32r2 -EL -O2 -G0 -mno-abicalls -fno-pic -ffreestanding -fno-builtin -nostdlib -no-pie -static \
    -Wl,-T,fbpaint.ld -Wl,--build-id=none -o fbpaint.elf start.S fbpaint.c
  mipsel-linux-gnu-objcopy -O binary fbpaint.elf fbpaint.bin
  $cc -O2 -static -o fbinfo fbinfo.c
'
