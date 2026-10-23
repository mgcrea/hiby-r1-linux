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
- **Already X1600-aware:** dwc2 (`ingenic,x1600-otg`). The 7.3 release has no X1600 pin data in `pinctrl-ingenic` (an earlier note said it had; master was not rechecked).
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

## Plan (approved 2026-10-22)

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
## Mainline on the R1 (2026-10-23)

- **Status:** Linux 7.3 boots through `r1jump` to a busybox initramfs, with its console on the screen, a shell over USB serial and the SD card mounted read-only. Stages 1 (SoC base to a console) and 2 (MMC and USB gadget, as a serial shell rather than ADB) are reached without X1600 clock or pin drivers: everything runs on what the stock kernel set up.
  - **Verified from a photo of the screen:** system type X1600, `Ingenic XBurst V0.0 FPU V0.0`, BogoMIPS 1099.36 (as under the stock kernel); 56,960 KB total and 49,864 KB free (stock leaves about 1.5 MB free); `simple-framebuffer` registers fb0 and the console runs at 60×50; `/init` starts at 0.28 s and the uptime advances. No errors visible.
- **Building:** `kernel/build.sh` builds in a native arm64 Docker image (an amd64 image under emulation took about 135 s even with nothing to do; native takes about 30 s from scratch and 3 s for a small change). It keeps a 7.3 tree in the `r1-linux` Docker volume (Linux needs a case-sensitive filesystem), applies `kernel/patches/` only when they changed (re-applying them touches `asm/cpu.h`, which nearly everything includes), merges `kernel/r1.config` into `cu1000-neo_defconfig` only when it changed and writes `kernel/out/r1-linux.bin` (vmlinux.bin with the DTB appended, `MIPS_RAW_APPENDED_DTB`). It prints the load address (0x80100000) and entry point. To change the kernel, commit on branch `r1` in the volume tree, then `build.sh patches`.
- **Booting:** `kernel/tools/boot.sh` pushes `r1-linux.bin` and `r1jump.ko`, pauses r1player, redirects the display (below) and jumps. In the new kernel, `kernel/tools/r1sh.py 'cmd' ...` runs commands over the USB serial gadget (it finds the port by its USB name, "Gadget Serial", since an ESP32 also shows up as `/dev/cu.usbmodem*`), and `r1-reboot` there brings the R1 back to r1player in about 7 s. Otherwise the watchdog does, about 0.7× the `wdt_secs` given (its real rate isn't the assumed 32 Hz; not investigated).
- **What the X1600 needed:**
  - **PRId:** the core reports 0x00d00000 (company Ingenic D0, implementation 0), which `cpu_probe_ingenic()` rejects with a silent `panic("Unknown Ingenic Processor ID!")` before any console exists. A patch handles it like the X1830's XBurst1.
  - **OST timer:** same registers as the X1000 (`ingenic,x1000-ost`), but on CPU interrupt 4, not 3. Its only clock input is a fixed 24 MHz `ext`.
  - **Interrupt controller:** the X1000/JZ4780 one at 0x10001000, on CPU interrupt 2.
  - **Display:** left running by the stock kernel. The controller at 0x13050000 uses a different layout from the X1000's: register 0x1000 holds the address of a self-linked frame descriptor in RAM, whose second word is the page being shown, and the controller rereads it every frame. The stock kernel allocates that descriptor anywhere and replaces it when r1player flips pages (seen at 0x02518000, 0x00B68000, 0x02535000), so `boot.sh` chains it to a self-linked copy showing page 0, in the last row of page 1 (0x02776F00). That memory belongs to the stock framebuffer, so nothing on the stock side hands it out before the jump, and the device tree reserves both pages; `simple-framebuffer` draws on page 0 only. Three ways this went wrong first: assuming a fixed address (the console ended up on the hidden page); a page just past the framebuffer (r1jump allocated it as free memory and overwrote it, and the screen went to garbage); and the boot marks painting both pages (the last stripe overwrote the descriptor, giving vertical lines).
  - **The stock device tree** is readable at `/sys/firmware/fdt`; a decompiled copy is in `kernel/out/stock-dt/` (untracked) and gives every block's address and interrupt.
- **USB (stage 2, 2026-10-23):** the DWC2 at 0x13500000 (`ingenic,x1600-otg`, intc 1) works as a peripheral, with the PHY and clocks as the stock kernel left them. The built-in `g_serial` gadget gives a shell on `/dev/cu.usbmodem*`. `dr_mode = "peripheral"`: in OTG mode the controller takes the host role with a USB-C cable to the Mac.
- **SD card (stage 2):** on **MSC1** (0x13460000, intc 36), not MSC0, despite the stock tree's `mmc0` alias pointing at MSC0 (MSC0 is probably the Wi-Fi chip's SDIO link). The X1600's MSC has the X1000's JZ layout, so `jz4740_mmc` (`ingenic,x1000-mmc`) drives it; the stock kernel's many `sdhci_*` symbols are a red herring. It runs in PIO mode (no DMA yet) at about 18 MB/s, and the initramfs mounts the exFAT partition read-only at `/mnt/sd`.
- **Stock clock rates** (from the stock kernel's `/sys/kernel/debug/clk/clk_summary`, saved in `kernel/out/stock-dt/clk_summary.txt`): APLL and CPU 1104 MHz, MPLL 1.4 GHz, EPLL 300 MHz, AHB2 280 MHz (OTG), APB 140 MHz, MSC0 and MSC1 50 MHz (MPLL / 28). The fixed stand-in clocks in `x1600.dtsi` use these. Decoding the PLL registers with the X1830's field layout gives wrong rates (MPLL 1056 MHz).
- **Command line:** taken from the device tree's `bootargs` only (`MIPS_CMDLINE_FROM_DTB`); with a built-in one (as `cu1000-neo_defconfig` has), MIPS ignores `bootargs`.
- **Boot marks:** the `DEBUG` patch paints a 16-row stripe on framebuffer page 0 at each milestone: black at row 352 (first instruction of `kernel_entry`), grey at 376 (BSS cleared), then `start_kernel` steps from row 400 (n = 0..8) and `setup_arch` steps (n = 10..16), every 24 rows. This is how the PRId panic was found.
- **Kernel log after the reset:** mostly lost. `__log_buf` (phys 0x976134) lies past the stock kernel's image, but the stock system reuses that memory before ADB comes up.

- **Jumping to our own code works (2026-10-23).** `r1jump` loaded `kernel/tools/fbpaint` (176 bytes at `0x80010000`), which painted colour bands over the whole screen; the watchdog brought the R1 back about 15 s later.
  - **Why the first attempt failed:** the stub, its params and the page list were written through cached KSEG0 but executed and read through uncached KSEG1, so the CPU ran stale RAM (254 of the stub's 276 bytes hadn't reached it). `r1jump` now writes them back from L1 and L2 first, and a dry run prints `uncached view differs: stub 0, params 0, list 0 bytes` to show it.
  - **The screen is a debug channel:** the LCD controller refreshes continuously at 60 Hz (the `jzfb` interrupt), straight from the framebuffer at physical `0x02600000` (480×800 RGB565, 960-byte lines, two pages). A new kernel can paint progress there with uncached stores and no display driver, as long as it leaves the LCD controller and its clocks alone. Writes from Linux through `/dev/mem` show up too.
- **Debugging without serial:** chosen for now because the user has no adapter where they are. This only works if RAM survives a reset plus the stock boot; `kernel/tools/ramtest.sh` measures it (`mark`, reset with `reboot` or `r1jump wdt_only=1`, then `check`).
  - **First run (2026-10-22, watchdog reset, `check` about 4 minutes after boot):** DRAM keeps its contents through the reset and the SPL: 2 marker pages, and about 1.1 MB of stale data near the top of RAM (`0x03eb8000`–`0x04000000`), came back bit-for-bit. But only 2 of 1044 marker pages survived; the stock boot and `hiby_player` had reused the rest, top of RAM included. Pages that changed hold structured data (they compress well), not decayed bits.
  - **Consequence:** a crash log has to be found before the stock system overwrites it: dump as soon as adb comes up, and give the log a magic header so it can be found wherever it survives. Not measured yet: how much survives at the first moment adb is up.

## Not yet verified

- Volume Up + Power at boot starting the SD-card recovery that reflashes `r1.upt`. Both community repos report it; it hasn't been tried on this unit.
- What the SPL does with the ADC key it reads (string `adc key:%d`).
- Whether `rootfs2`/`kernel2` hold a recovery system or a copy of the main one.
