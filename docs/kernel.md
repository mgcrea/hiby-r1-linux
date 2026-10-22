# Kernel: boot chain, stock-kernel facts and the mainline port

Read this before working in `kernel/` or on anything that boots a kernel
other than the stock one. Observed on the R1 with patched firmware 1.6 on
2026-10-22 unless marked otherwise.

## Boot chain (verified)

- **Bootloader:** `mtd0` holds only a U-Boot SPL (`U-Boot SPL 2013.07-g3fccbcd`, built 2025-01-16). It uses about 16 KB of the 512 KB partition, the rest is erased. It boots Linux directly (falcon mode); there is no full U-Boot, no U-Boot console and no display init, so nothing lights the screen before Linux.
- **Kernel slot:** the first bytes of `/dev/mtd5` (`ota`) read `ota:kernel`, space-padded. The SPL also knows `ota:kernel2`, which boots `kernel2` + `rootfs2`.
- **Command line:** baked into the SPL, one variant per slot, differing only in `root=/dev/mtdblock_bbt_ro2` vs `ro4`. Running: `console=ttyS2,3000000n8 quiet mem=64M@0x0 init=/linuxrc flashtype=nand root=/dev/mtdblock_bbt_ro2 rootfstype=squashfs ro`.
- **Kernel image:** legacy uImage (`file firmware/stock/xImage`), load and entry `0x80F00000`, a self-decompressing gzip payload of 3.7 MB. The kernel partitions (`mtd1`, `mtd3`) are 5 MB each.
- **Serial console:** UART2 at 3,000,000 baud. Where its pads are on the board is not known.
- **Reading the bootloader:** `cat /dev/mtd0` works over ADB (read-only use only). A dump is in `firmware/device/`.

## The stock 4.4 kernel (verified)

- **No kexec:** `sys_kexec_load` appears in `/proc/kallsyms` only as a weak stub.
- **`/dev/mem`:** reads all 64 MB of RAM, kernel included. `kptr_restrict` is 0.
- **Memory map:** kernel text and data run from `0x80010000` (`_text`) to `0x808f9b10` (`_end`); the init section from `0x807a2000` is freed after boot. Physical address = virtual − `0x80000000`.
- **Reading stock code:** there's no vmlinux, but a function can be disassembled from RAM: find it in `/proc/kallsyms`, `dd` its pages out of `/dev/mem` on the device, `adb pull`, and run `mipsel-linux-gnu-objdump -D -b binary -m mips:isa32r2 -EL --adjust-vma=<page addr>` in the `r1-stock-modules` image.
- **Watchdog and reboot:** the stock `ingenic_wdt` driver's restart handler arms the watchdog for 160 ticks, so `reboot` is itself a watchdog reset. The X1600 watchdog doesn't use the JZ4740 register layout; `r1jump`'s `arm_watchdog` copies the stock sequence, and `insmod r1jump.ko wdt_only=1 wdt_secs=5` reset the R1 as expected.
- **Module loading:** accepts unsigned out-of-tree modules with no symbol versions. Vermagic is `4.4.94+ preempt mod_unload MIPS32_R2 32BIT `.
- **Building modules:** `kernel/tools/stock-modules/build.sh` builds them from a vanilla kernel.org 4.4.94 tree whose `struct module` matches stock. Check a result with `layout.py` and `imports.py`, run as `uv run --with pyelftools python ...` (the latter needs `/proc/kallsyms` saved to `kernel/out/stock-kallsyms.txt`). The `probe` module loads and unloads on the device.
- **Trap: inline helpers.** Only `struct module` is known to match. Inline helpers that read other kernel structs compile cleanly but misbehave: `alloc_page()` returned NULL on the first call with plenty of free memory. Other examples are `page_to_phys`, `page_address`, `file_inode`, `i_size_read` and `kmalloc`/`kcalloc` (which index the slab caches inline). A module must stick to exported functions (for example `__get_free_pages` and `kernel_read`), and `imports.py` must report nothing missing. `r1jump` follows this and its dry run works.
- **Trap: the OOM killer reboots the R1.** About 15 MB is available while `hiby_player` runs. When a module or `/tmp` (tmpfs, so RAM) takes more, the OOM killer picks `hiby_player` and its launcher reboots the device; this happened with an 8 MB image in `/tmp` plus `r1jump`'s 8 MB copy. Allocate in modules with `__GFP_NORETRY | __GFP_NOWARN`, which in 4.4 fails instead of invoking the OOM killer (verified on the same case).
- **busybox `insmod`** calls a module's init twice when it fails, so its log lines appear twice.

## Mainline status (checked against torvalds master, 7.3 / 7.4 merge window, 2026-10-22)

- **No X1600 platform:** there's no `MACH_X1600`, no X1600 clock (CGU) driver and no `x1600.dtsi`. Ingenic support stops at the X1000 and X1830.
- **Already X1600-aware:** `pinctrl-ingenic` (X1600 pin data; its `IS_ENABLED(CONFIG_MACH_X1600)` refers to an option that doesn't exist yet) and dwc2 (`ingenic,x1600-otg`).
- **Probably reusable through the X1000 compatibles:** UART, I2C, TCU/timers/PWM, OST, MMC, DMA, I2S and SPI (SSI).
- **Board chips covered:** CS43131 (`cs43130` driver), CW2015, BCM43430 Wi-Fi (`brcmfmac`). Touch may be covered by `hynitron,cst816s`; not checked against the R1's `cst8xx`.
- **Missing:**
  - AXP2101 PMIC;
  - the Ingenic SFC (the internal NAND flash controller);
  - an X1000/X1600 LCD controller in `ingenic-drm`;
  - the LG35583 panel;
  - the SADC (ADC keys);
  - Rust-for-Linux (no MIPS support).

## References

- **Ingenic's X1600 SDK** (`ingenic-linux-kernel4.4.94-x1600-v6.0-20240606`): the vendor kernel source. It is not redistributable and we don't have it.
- **[Jepl4r/hiby-custom-kernel](https://github.com/Jepl4r/hiby-custom-kernel):** rebuilds the 4.4 kernel for the R1 from that SDK. Its GPL sources for 38 of HiBy's closed modules (LG35583 panel, `cst8xx_touch`, AXP2101, CS43131 sound card, MMC, LCD, I2S) are the best register-level reference for a port.
- **[MatthewBriggs/hiby-r1-linux-kernel-compiling](https://github.com/MatthewBriggs/hiby-r1-linux-kernel-compiling):** the same work, documented step by step.
- **Rockbox `utils/jztool/src/x1600.c`:** X1600 boot-ROM USB loading with a DDR-init stage. In boot-ROM mode the R1 enumerates as `a108:eaef`. How to enter that mode on the R1 was not found.
- **[Ingenic-community/linux](https://github.com/Ingenic-community/linux):** 6.1, with X1600 support mostly untested.

## Plan (approved 2026-10-22, no port code written yet)

- **Target:** current mainline, kept as a patch series in `kernel/`.
- **Boot:** the stock SPL and its kernel partition, with the device tree built in.
- **Root filesystem:** an initramfs that mounts the SD card and boots a squashfs image file stored on it. The card isn't repartitioned and no SFC driver is needed at first.
- **Stages:**
  1. SoC base and clocks, to a console;
  2. MMC and USB gadget (ADB);
  3. display, touch and keys;
  4. audio;
  5. AXP2101 and power;
  6. later: NAND, Wi-Fi/BT, USB DAC.
- **First real jump (2026-10-22): failed, cause unknown.** `r1jump` loaded `kernel/tools/fbpaint` (176 bytes at `0x80010000`; paints colour bands into the framebuffer at `0x02600000`, which the LCD controller keeps scanning out, then spins) with the screen on and `hiby_player` stopped. No bands appeared; the watchdog brought the R1 back about 17 s later. Not yet known whether the stub's cache maintenance, the copy, or the jump itself goes wrong.
- **Debugging without serial:** chosen for now because the user has no adapter where they are. This only works if RAM survives a reset plus the stock boot; `kernel/tools/ramtest.sh` measures it (`mark`, reset with `reboot` or `r1jump wdt_only=1`, then `check`).
  - **First run (2026-10-22, watchdog reset, `check` about 4 minutes after boot):** DRAM keeps its contents through the reset and the SPL: 2 marker pages, and about 1.1 MB of stale data near the top of RAM (`0x03eb8000`–`0x04000000`), came back bit-for-bit. But only 2 of 1044 marker pages survived; the stock boot and `hiby_player` had reused the rest, top of RAM included. Pages that changed hold structured data (they compress well), not decayed bits.
  - **Consequence:** a crash log has to be found before the stock system overwrites it: dump as soon as adb comes up, and give the log a magic header so it can be found wherever it survives. Not measured yet: how much survives at the first moment adb is up.

## Not yet verified

- Volume Up + Power at boot starting the SD-card recovery that reflashes `r1.upt`. Both community repos report it; it hasn't been tried on this unit.
- What the SPL does with the ADC key it reads (string `adc key:%d`).
- Whether `rootfs2`/`kernel2` hold a recovery system or a copy of the main one.
