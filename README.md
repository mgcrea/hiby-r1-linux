# Mainline Linux for the HiBy R1

A port of current mainline Linux (7.3) to the [HiBy R1](https://store.hiby.com/), a
small touchscreen music player built on the Ingenic X1600E. It replaces HiBy's
4.4 vendor kernel and system with an upstream kernel, a small initramfs and the
app of your choice, started from the SD card.

This is an unofficial project, not affiliated with or endorsed by HiBy.

> [!WARNING]
> This writes your R1's internal flash. Read
> [Recovery](#recovery) before you install anything, and keep HiBy's
> original `r1.upt` update file at hand.

## What works

On the R1, from its own flash (since 2026-10-24):

- **Display:** a DRM driver for the X1600's LCD controller, the LG35583 panel and the
  PWM backlight.
- **Input:** touch (CST816S) and all five keys.
- **Audio:** the CS43131 DAC over I2S, at 44.1 and 48 kHz (96 kHz and up don't work
  yet).
- **Power:** the AXP2101 PMIC and the battery gauge, plus the watchdog.
- **Storage:** the SD card, and the internal SPI-NAND through a new SFC driver.
- **USB:** a serial shell, ADB, and the SD card shared with a computer as a USB disk.
- **Bluetooth:** A2DP to headphones, through BlueZ and bluez-alsa.
- **Wi-Fi:** the chip scans; connecting isn't done.

[docs/kernel.md](docs/kernel.md) has the details, measurements and open
issues. The patches are being sent upstream one series at a time; its
"Mainline submissions" section tracks them.

## How it boots

1. HiBy's boot loader (left untouched) starts a mainline kernel from the
   `kernel` flash slot.
2. That kernel kexecs the newer kernel on the SD card (`/.r1-mainline/r1-linux.bin`),
   so updating the kernel only means copying a file to the card.
3. The initramfs mounts the card and a system image from flash with the few
   stock programs it reuses (adbd, dbus, BlueZ, bluez-alsa, wpa_supplicant). Then it
   starts the app at `/.r1-mainline/app`, restarting it whenever it exits.
   Without an app, the screen shows a clock and the shell stays on USB.

An app is any MIPS32r2 hard-float binary linked against the R1's glibc 2.22 (for
Rust, `mipsel-unknown-linux-gnu.2.22`). It draws on `/dev/fb0`, reads
`/dev/input/event*`, plays through ALSA (or bluez-alsa for headphones) and finds
the card at `/mnt/sd_0`. State that has to outlive a restart goes to
`$R1_STATE` on the card, since `/usr/data` is in RAM.
[docs/r1-device.md](docs/r1-device.md) lists the hardware an app sees.

## Layout

| Path | What |
|---|---|
| `kernel/patches/` | the patch series against Linux 7.3 |
| `kernel/build.sh` | builds the kernel, its modules and the flash image in Docker |
| `kernel/initramfs/` | init and the scripts it runs (USB, Bluetooth, Wi-Fi, card sharing) |
| `kernel/tools/` | flashing, card install, USB boot, and tools for the stock kernel |
| `firmware/` | builds a patched HiBy update with ADB, the way in from stock |
| `docs/` | how the R1 and its boot chain work, and the port's notes |

HiBy's own files (the stock update, its root filesystem, the system image built
from it) aren't in this repository and never will be. Every tool here builds
from your own copy of HiBy's firmware 1.6 update, unpacked in `firmware/stock/`.

## Building

- **Kernel:** `kernel/build.sh` (needs Docker; the kernel tree lives in a Docker
  volume because Linux needs a case-sensitive filesystem). It writes
  `kernel/out/r1-linux.bin` for the card and `kernel/out/r1-linux.uimage` for the
  flash slot.
- **System image:** `kernel/tools/mksystem.py` (with `R1_APP=` set to your app's
  build, so its libraries are included).
- **ADB firmware for a stock R1:** `firmware/build.sh`, which also checks its
  output against stock with `firmware/verify.sh`.

Getting a stock R1 onto mainline is a developer process for now:
1. Flash the ADB firmware.
2. Put the kernel on the card.
3. Install the flash kernel with `kernel/tools/flash-install.sh`.

[docs/r1-device.md](docs/r1-device.md) and [docs/kernel.md](docs/kernel.md)
describe each step and what was verified.

## Recovery

HiBy's recovery stays intact: hold **Volume Up** while switching the R1 on,
with an `r1.upt` update file at the root of the SD card, and it reflashes
that update. With HiBy's original `r1.upt`, that brings back the stock
system.

If the card's kernel doesn't come up, every later start stays on the flash
kernel until `r1-linux.bin` changes. Holding Volume Down at power-on also
stays there. The last boot's log is in `/sys/fs/pstore`.

## License

GPL-2.0, like the kernel the patches apply to. See [LICENSE](LICENSE).
