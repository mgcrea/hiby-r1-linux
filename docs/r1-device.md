# HiBy R1: device facts and decisions

Observed on a HiBy R1 running official firmware 1.6 (December 2025 build),
2026-10-22, unless marked otherwise. Device paths cross-checked against
Rockbox's hosted R1 port (`firmware/target/hosted/hiby/` in the Rockbox tree),
which is the best reference for anything not listed here.

## Hardware and OS

- **SoC:** Ingenic X1600E, MIPS32r2 with FPU, 1 GHz.
- **Caches** (from Config1/Config2): L1 I and D 16 KB each, L2 128 KB, all with 32-byte lines.
- **Kernel and userland:** Linux 4.4.94 (built 2025-12-29), Buildroot 2020.02, glibc 2.22 hard-float o32 (`/lib/ld.so.1`).
- **RAM:** 56 MB. About 17 MB is available while `hiby_player` is paused, because a stopped process keeps its 14 MB resident.
- **Display:** `jzfb`, 480×800 RGB565, two pages stacked vertically (`yres_virtual` 1600), switched with `FBIOPAN_DISPLAY`. `read()` on `/dev/fb0` returns page 0 only, whichever page is on screen. That's why `./dev shot` goes through `r1player --shot`. Near-white greys turn pink in RGB565, because green keeps 6 bits and red and blue 5 (0xf9fafb and 0xf2f3f5 both showed it, 2026-10-23); a grey whose 5- and 6-bit expansions agree stays grey, such as 0xefefef or 0xffffff.
- **Backlight:** `/sys/class/backlight/backlight_pwm0`, max 101. `hiby_player` can leave it at 0 when it's paused, so the screen looks dead.
- **Inputs:**

  | Device | Name | Events |
  |---|---|---|
  | `event0` | `md-gpio-keys` | power 116, next 163 |
  | `event1` | `hyn_ts` | touch: `BTN_TOUCH` plus MT positions in panel pixels, although it advertises a 0–720 × 0–1280 range |
  | `event2` | `jz adc keyboard` | play/pause 164, volume up 115, volume down 114 |
  | `event3` | `earpods_adc` | headset remote |

- **Audio device:** card 0 only (`pcmC0D0p`, `controlC0`), with a CS43131 DAC. There is no `/proc/asound`.
- **PCM format:** the PCM rejects S32_LE and accepts S16_LE and S24_LE (24 bits in a 32-bit container) stereo at 44.1 kHz; r1player plays S24_LE cleanly (2026-10-23). Other rates weren't tried.
- **Mixer controls:**
  - `Output Port Switch` must be 2 for headphones (verified). Rockbox uses 3 for balanced (not verified). The default 0 is silent.
  - `Left/Right Playback Volume` (0–255) always read back 0, even after `amixer cset`, so the player does volume in software. Rockbox treats the value as attenuation in 0.5 dB steps, with 0 the loudest.
  - Others: `Mute Output`, `Soft Mute`, `DOP_EN`, `Digital Filter`.
- **Headphone detection:** `/sys/class/switch/headset/state`. This unit has no `balance` switch file.
- **SD card:** `/dev/mmcblk0p1`, exFAT. The stock player mounts it at `/mnt/sd_0` and unmounts it whenever it hands the card to a USB host.
- **Names copied from macOS:** they contain SFM private-use characters (U+F020–F029) in place of characters that FAT/exFAT forbid. See `library::display_name`.
- **Font:** `/usr/resource/fonts/default.otf` is Noto Sans SC DemiLight (CJK, CFF, 30,888 glyphs, complete Latin-1), but its `…` is drawn at mid-height.
- **Flash (`/proc/mtd`):** uboot, kernel, rootfs, kernel2, rootfs2, ota, userdata. userdata is UBIFS, mounted at `/usr/data`. How the bootloader picks a slot is in `docs/kernel.md`.
- **Process layout:** `/usr/bin/hiby_player.sh` runs `reboot` when `hiby_player` exits. Pause it with SIGSTOP; don't kill it.

## Getting a root shell (ADB)

- **Stock 1.6 has no ADB at all.**
  - The "USB device mode" setting is hidden by `"usb_mode":0` in `usr/resource/set_functions.json`.
  - Un-hiding it (tried) offers only Audio and Storage. There's no Dock (ADB) choice.
  - The `T90adb` init script never runs, because `rcS` only runs `S??*` scripts.
- **The ADB image (`firmware/out/r1.upt`)** is stock 1.6 plus an ADB block appended to `/usr/bin/usb_storage_init.sh`. `hiby_player` calls that script just before it binds the `android0` USB gadget, so the device comes up as storage plus ADB together.
  - An empty `.noadb` file at the SD card root disables it.
  - USB DAC mode may fail while ADB is on: `uac_device_config.sh` refuses to start if a gadget already exists. Not tested.
- **Since 2026-10-24 the R1 boots mainline from its own flash** (`docs/kernel.md`, "Replacing stock in flash"): no stock system runs any more. The auto-jump firmware below is still in `rootfs` and comes back with Volume Up at power-on (its `r1.upt` is at the card root); then `kernel/tools/flash-install.sh` puts mainline back.
- **Before that, the R1 ran the auto-jump firmware (`firmware/out/r1player/r1.upt`, flashed 2026-10-23 22:18):** the r1player firmware below, whose launcher first runs `/usr/bin/r1-mainline.sh`. That script jumps into the mainline kernel on the card (`/.r1-mainline/r1-linux.bin`, `r1jump.ko` and `entry`, put there by `kernel/tools/sdsync.sh`), which runs `/.r1-mainline/r1player`; mainline is up about 11 s after a reboot. It stays on stock, with ADB, when `.stock` or `.no-mainline` is at the card root, there is no card, or mainline failed twice in a row (a watchdog reset after a jump counts as one, read from the reset-cause register at 0x10000008; a power-on clears the count, kept in `/usr/data/r1player/mainline-fails`). Its decision is logged in `/usr/data/r1player/mainline.log`. ADB shows `HiBy R1` for a few seconds during every stock start, before the jump, so wait for `staying on stock` in that log rather than for `adb devices`. So without anyone at the R1: `r1-reboot` twice from mainline's shell reaches stock; `rm /usr/data/r1player/mainline-fails` and a reboot go back (tested 2026-10-23). It reads no key: Next held while the R1 starts selects the SoC's USB boot mode (`docs/kernel.md`, "Boot chain").
- **The r1player firmware (flashed 2026-10-22):** the ADB image plus a new `/usr/bin/hiby_player.sh` that runs `/usr/data/r1player/r1player` in place of the stock player.
  - It mounts the card read-only at `/usr/data/mnt/sd_0` and binds the USB gadget with ADB only, so the Mac sees no storage while r1player runs.
  - The stock `hiby_player` takes over when a `.stock` file exists at the card root, or when r1player is missing. When r1player exits non-zero (including `kill -9` over ADB), the launcher writes `/usr/data/r1player/stock-once` and reboots; the next boot runs the stock player and deletes the flag. Firmware updates still go through the stock player's Settings.
  - r1player exiting 0 (it does on SIGTERM) relaunches it; `./dev run` uses that to deploy. Its output goes to `/usr/data/r1player/r1player.log` (`.old` keeps the previous boot's). It takes commands on the named pipe `/tmp/r1player.ctl` (`play PATH`, `key playpause`, `tap X Y`...) and writes its state to `/tmp/r1player.status`: `adb shell "echo 'key next' > /tmp/r1player.ctl"` drives it without anyone at the R1 (see `player/src/ctl.rs`).
  - It keeps its state in `/usr/data/r1player`: the library index, covers and thumbnails, `scores` (best scores, and where each game starts as `<game>.progress`: chosen in Settings → Games, and moved by Sums and Clock as they're played) and `settings` (brightness, screen off, volume and its limit, Bluetooth on or off and the last headset), both as `key value` lines. Deleting `settings` brings back the defaults. Under mainline `/usr/data` is in RAM, so r1player also copies `scores`, `settings` and BlueZ's pairings to `$R1_STATE` on the card after each change, and init copies them back at boot (`player/src/state.rs`, `docs/kernel.md`).
  - Verified on the first boot: r1player draws its UI, ADB comes up without `hiby_player`, and `free` reports 34.7 MB available (about 19 MB under the stock player).
  - **Why the fallback reboots:** `hiby_player` opens `/dev/sa_hgl_dma`, whose driver allocates 8 MB of physically contiguous memory (an order-11 `dma_alloc_coherent`). After r1player has run for a few seconds no such block is left, and this kernel has no memory compaction (`/proc/sys/vm/compact_memory` is absent; `drop_caches` doesn't help). The open fails (`hgl_fb: E) Access hgl dma failed`, and `sahd_open: malloc hgl memory error` in dmesg), and `hiby_player` runs without a display, though it does resume playback. Started first thing after boot, it works. Verified 2026-10-22: `kill -9` on r1player rebooted into a working stock UI, and the boot after that ran r1player again.
  - **Unplugging breaks ADB until a restart (2026-10-23).** On unplug the vendor kernel unbinds the gadget (`/sys/kernel/config/usb_gadget/android0/UDC` goes empty); on replug the OTG controller comes up as a USB host and enumerates the Mac as a device (`New USB device found, idVendor=05ac`). `hiby_player` handled this; the launcher doesn't. Rebinding `UDC` from a watcher loop doesn't help: the gadget binds again, but on replug the controller still takes the host role. The cause is the USB-C controller: the stock firmware leaves the TCS1421 dual-role (its CFG0/CFG1 pins, PA9 and PB24, both high), so a plug-in can attach as a source; `docs/kernel.md` ("USB-C role") has the details. Untested on stock: writing `Sink` to `/sys/devices/platform/tcs1421/tcs1421_cfg` from the launcher might keep ADB alive across replugs. The mainline kernel survives a replug (the port held as a sink, plus a `dwc2` fix, `docs/kernel.md`); on the stock kernel, restart the R1 after unplugging it.
  - Not verified yet: audio without `hiby_player` having initialised the codec, power-off and low-battery behaviour with no stock UI.
- **Building an image:** `firmware/build.sh` applies `firmware/overlay/` to the stock rootfs, then `repack.sh` builds the `.upt` and `verify.sh` checks it against stock. The script comments describe the `.upt` format (ISO 9660, chained-MD5 chunks, no signature).
- **Installing and reverting:** since 2026-10-24 no stock player runs, so the only way to flash an `r1.upt` is Volume Up held at power-on with it at the card root (HiBy's recovery, `docs/kernel.md`). Before that, the user put `r1.upt` at the SD card root and ran Settings → Firmware update. The update flashes whatever `r1.upt` is on the card, so compare its md5 with the build first: a stale copy once reflashed the previous image. While the stock player runs, the card is mounted read-write at `/usr/data/mnt/sd_0`, so the image can be pushed there with `adb push`. To go back, flash the stock `~/Downloads/r1.upt` (sha256 `9aada819…ba60`) the same way.
- **On the host:**
  - adb lists the R1 as `(no serial number) … model:Nexus_4`, and the shell runs as root.
  - The USB gadget's serial string is empty, which adb's libusb backend drops silently. Start the adb server with `ADB_LIBUSB=0`.
  - The R1's adbd predates `adb exec-out` (it fails with `error: closed`), and `adb shell` runs commands on a pty, which mangles binary output. Pull a file with `adb pull`, or stream bytes as `adb shell '... | gzip -1 | base64' | tr -d '\r' | base64 -d | gunzip` (about 3 s per MB). There's no `nc` on the device.

## Decisions

- **Stock kernel:** the player runs on the stock 4.4 kernel. A port to mainline started on 2026-10-22; see `docs/kernel.md` for its status, the boot chain and the references.
  - The panel (`lcd_lg35583`), touch (`cst8xx_touch`), PMIC (`axp2101`) and sound-card glue are closed vendor modules in `/module_driver`. Open GPL rewrites of them exist; `docs/kernel.md` lists them.
- **Toolchain:** `mipsel-unknown-linux-gnu.2.22` (hard float, linked against the device's glibc), not the musl target, which is soft-float.
  - Measured with symphonia on the R1: MP3 decodes at 16.5× real time hard-float vs 1.9× soft-float; M4A at 25× vs 3.4×.
  - MIPS targets are Rust tier 3, so the build needs nightly and `-Zbuild-std`.
  - Versions used: Rust nightly 1.101, zig 0.17, cargo-zigbuild 0.24 (2026-10-22).
- **Opus:** symphonia 0.6.1 demuxes Ogg Opus but has no Opus decoder, so the player uses the pure-Rust `opus-decoder` crate. The Tonies files on the card are Opus.
- **Album covers:** these are often 3000×3000 JPEGs, which would need 27 MB at full size. `jpeg-decoder` shrinks baseline JPEGs during decoding (DCT scaling), which `zune-jpeg` can't do.

## Not yet verified

- Pause when the headphones are unplugged, long-press next for the previous track, the power-button screen toggle, and fling scrolling have not been confirmed on the device.
- Whether the hardware volume controls do anything.
- Balanced output (port 3).
