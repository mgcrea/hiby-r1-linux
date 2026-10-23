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
- **busybox `insmod`** calls a module's init twice when it fails, so its log lines appear twice, and reports a missing file (r1jump's `image=`, after a reset wiped `/tmp`) as "unknown symbol in module, or unknown parameter".

## Mainline status (checked against torvalds master, 7.3 / 7.4 merge window, 2026-10-22)

- **No X1600 platform:** there's no `MACH_X1600`, no X1600 clock (CGU) driver and no `x1600.dtsi`. Ingenic support stops at the X1000 and X1830.
- **Already X1600-aware:** `pinctrl-ingenic` (full X1600 pin data, `ingenic,x1600-pinctrl` and `ingenic,x1600-gpio`, compiled in only with `CONFIG_MACH_X1600`, which upstream doesn't define; our patch 0001 adds it), dwc2 (`ingenic,x1600-otg`). Verified in the 7.3 release; master's `pinctrl-ingenic.c` was identical on 2026-10-22. (A note in between wrongly said 7.3 lacked the pin data: a `grep -rl ... | head` cut the list before reaching it.)
- **Probably reusable through the X1000 compatibles:** UART, I2C, TCU/timers/PWM, OST, MMC, DMA, I2S and SPI (SSI).
- **Board chips covered:** CS43131 (`cs43130` driver), CW2015, BCM43430 Wi-Fi (`brcmfmac`), the touch panel (`hynitron,cst816s`, verified 2026-10-23).
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

- **Status:** Linux 7.3 boots through `r1jump` to a busybox initramfs, with its console on the screen, a shell over USB serial and the SD card mounted read-only. Stages 1 (SoC base to a console) and 2 (MMC and USB gadget, as a serial shell rather than ADB) are reached, and since stage 3a the clocks and pins come from real X1600 drivers (patches 0005 and 0006) instead of stand-ins. Audio (stage 4) plays at 44.1 and 48 kHz and touch works; the keys and the display driver are still missing.
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
- **X1600 clock driver (`x1600-cgu.c`, stage 3a, 2026-10-23):** the register map was read out of the running stock kernel, not guessed. `kernel/tools/stock-modules/clkdump` (a stock-kernel module; only exported functions plus `__clk_lookup` through `kallsyms_lookup_name`) logs every stock clock with its rate, parent, ops symbol and the raw driver structure behind it; `kernel/tools/clkdecode.py` groups them by type. Each mux's parent list came from its `clk_core` (`parent_names` at +20, `num_parents` at +28, verified by the name at +0) read through `/dev/mem`, and the vendor tables `ingenic_mux_table` (identity), `x1600_clk_div_table` (MSC: 2(n+1)) and the PLL descriptors from their kallsyms addresses. The raw dump is `kernel/out/stock-dt/clkdump.txt` (untracked).
  - **PLLs:** rate = ext × M / (N × OD1 × OD0), M bits 31:20, N 19:14, OD1 13:11, OD0 10:8, no offsets (the vendor descriptors say so). The driver keeps them, and the CPU, L2, AHB, APB and DDR clocks, read-only.
  - **Muxes:** register value = parent index. SCLKA {stop, ext, APLL}; CPU/L2, AHB0, AHB2/APB, DDR {stop, SCLKA, MPLL}; peripherals {SCLKA, MPLL, EPLL} (CAN adds ext); I2S {SCLKA, EPLL}.
  - **CDR dividers:** as on the X1830 (change enable 29, busy 28, stop 27), 8 bits wide (4 for PWM and DDR). **Gates:** set-to-disable bits in CLKGR0 (0x20), CLKGR1 (0x28) and OPCR (0x24, bit 23 for the USB PHY). **I2S:** transmit at 0x7c and receive at 0x60, each a mux on bit 30 {SCLKA, EPLL}, an M/N fractional divider (rate = parent × M / N, M bits 28:20, N bits 19:0), an output enable on bit 29 and a gate in CLKGR1 (bit 9 transmit, bit 8 receive). Not in the driver yet: CAN, CDBUS and the memory power gates at 0xf8/0xfc.
  - **Check:** `kernel/tools/clkcompare.py` compares mainline's `clk_summary` with the stock dump: all 50 rates and gate states matched on the first boot.
- **Pins:** the X1600 pin controller (`ingenic,x1600-pinctrl`, 0x10010000, ports A–D every 0x100, GPIO interrupts 17/16/15/14 on intc) claims the SD card's pins (PD0–PD5, `mmc1`). Its GPIO registers (0x10–0x40, 0x70–0x90 per port) read identical under stock and under mainline.
- **Stock clock rates** (from the stock kernel's `/sys/kernel/debug/clk/clk_summary`, saved in `kernel/out/stock-dt/clk_summary.txt`): APLL and CPU 1104 MHz, MPLL 1.4 GHz, EPLL 300 MHz, AHB2 280 MHz (OTG), APB 140 MHz, MSC0 and MSC1 50 MHz (MPLL / 28). The fixed stand-in clocks in `x1600.dtsi` use these. Decoding the PLL registers with the X1830's field layout gives wrong rates (MPLL 1056 MHz).
- **Audio (stage 4, 2026-10-23):** a 440 Hz tone plays cleanly on the headphone output at 44.1 kHz; 44.1 and 48 kHz run at the right rate (measured from the PCM hardware pointer: 44,077 and 48,146 frames/s over 3 s). The chain is all mainline drivers: PDMA (`dma-jz4780` as an X1830, intc 3, AIC request lines 62 TX and 63 RX), the AIC (`jz4740-i2s`, intc 0) as I2S master, the I2S clock from EPLL, and the CS43131 (`cs43130`) on a bit-banged I2C bus (`i2c-gpio`, PB30/PB31, address 0x30, as the stock firmware drives it) behind a `simple-audio-card` with `mclk-fs = 512` (22.5792 / 24.576 MHz, HiBy's MCLKs). PB2 powers the DAC (a fixed regulator) and PB21 resets it. Three driver differences, each a patch:
  - **I2SDIV** holds the bit clock divider itself (not divider − 1 as on the X1000) and keeps only even values: writing 7 stores 6. With the X1000 settings 44.1 kHz played at 58.8 kHz (patch 0009).
  - **`cs43130`** takes the DAI `set_sysclk` frequency as SCLK, but `simple-audio-card` passes MCLK there, so it set up 256-bit slots and played white noise. Patch 0011 adds `set_tdm_slot`, and the R1's DT gives the codec two 32-bit slots (`dai-tdm-slot-num`/`-width`).
  - **`dma-jz4780`** dereferenced a NULL descriptor in `tx_status` after `terminate_all`, which ASoC calls when a stream closes: every close panicked (patch 0013; master has the same code).
- **96 kHz and up don't work yet:** `mclk-fs = 512` asks the DAC for a 49.152 MHz MCLK, and `cs43130` accepts only 22.5792 and 24.576 MHz. HiBy keeps those two MCLKs for every rate of each family; `simple-audio-card` can't say that.
- **Volume:** `Master Playback Volume` is attenuation in 0.5 dB steps from −127.5 dB (255 = 0 dB); it boots at 135 (−60 dB). No pop suppression: HiBy's driver mutes the DAC around every clock start and stop, mainline doesn't (pops not assessed yet).
- **Touch (2026-10-23):** the panel at 0x15 on I2C1 (PB19/PB20, function 0; intc 60, the stock tree's i2c1; I2C0 is intc 61) works with mainline's `hynitron,cst816s` driver, interrupt PA16 (falling), reset PA17. It reports panel pixels (480 × 800), though the driver advertises 0–240. The X1600 I2C controller differs from the X1000's in one register: the SDA set-up time is at 0xa0 (0x94 is the spike filter), and left at its reset value (116 APB cycles) every transfer ends in a lost arbitration (TXABRT 0x1000). Patch 0010 adds `ingenic,x1600-i2c`. Its power rail, the PMIC's ALDO2, stays on only because the stock kernel turned it on before the jump.
- **Testing tools in the initramfs:** `tinymix` and `r1tone [freq [dBFS [seconds [rate]]]]` (`kernel/initramfs/r1tone.c`), against a tinyalsa master commit from 2026-09-29: v2.0.0's `pcm_state()` hands the kernel a stale `appl_ptr` on MIPS (no mmap of the PCM status), so every write was dropped and nothing played. `r1sh.py --push LOCAL REMOTE` copies a file over the serial shell.
- **Command line:** taken from the device tree's `bootargs` only (`MIPS_CMDLINE_FROM_DTB`); with a built-in one (as `cu1000-neo_defconfig` has), MIPS ignores `bootargs`.
- **Boot marks:** the `DEBUG` patch paints a 16-row stripe on framebuffer page 0 at each milestone: black at row 352 (first instruction of `kernel_entry`), grey at 376 (BSS cleared), then `start_kernel` steps from row 400 (n = 0..8) and `setup_arch` steps (n = 10..16), every 24 rows. This is how the PRId panic was found.
- **Kernel log after the reset:** mostly lost. `__log_buf` (phys 0x976134) lies past the stock kernel's image, but the stock system reuses that memory before ADB comes up.

- **Jumping to our own code works (2026-10-23).** `r1jump` loaded `kernel/tools/fbpaint` (176 bytes at `0x80010000`), which painted colour bands over the whole screen; the watchdog brought the R1 back about 15 s later.
  - **Why the first attempt failed:** the stub, its params and the page list were written through cached KSEG0 but executed and read through uncached KSEG1, so the CPU ran stale RAM (254 of the stub's 276 bytes hadn't reached it). `r1jump` now writes them back from L1 and L2 first, and a dry run prints `uncached view differs: stub 0, params 0, list 0 bytes` to show it.
  - **The screen is a debug channel:** the LCD controller refreshes continuously at 60 Hz (the `jzfb` interrupt), straight from the framebuffer at physical `0x02600000` (480×800 RGB565, 960-byte lines, two pages). A new kernel can paint progress there with uncached stores and no display driver, as long as it leaves the LCD controller and its clocks alone. Writes from Linux through `/dev/mem` show up too.
- **Debugging without serial (superseded):** the user has no serial adapter. What works instead: the boot-mark stripes and the framebuffer console on screen, then the USB serial shell once the kernel is up. Recovering a crashed kernel's log from RAM after the reset does not: DRAM keeps its contents through a watchdog reset and the SPL, but the stock boot reuses free memory before ADB is up. `kernel/tools/ramtest.sh` measured it on 2026-10-22: 2 of 1044 marker pages left when checked 4 minutes after boot, 0 of 1040 when checked as soon as ADB came back (7 s).

## Not yet verified

- Volume Up + Power at boot starting the SD-card recovery that reflashes `r1.upt`. Both community repos report it; it hasn't been tried on this unit.
- What the SPL does with the ADC key it reads (string `adc key:%d`).
- Whether `rootfs2`/`kernel2` hold a recovery system or a copy of the main one.
