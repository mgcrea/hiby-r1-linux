#!/usr/bin/env bash
# Boot kernel/out/r1-linux.bin on the R1 through r1jump, from the stock
# kernel running r1player. Nothing is flashed: `r1-reboot` in the new
# kernel's shell, or the watchdog, brings the R1 back.
#
#   tools/boot.sh [wdt_secs]      default 600 (it runs about 1.4x fast)
#
# Then talk to it with tools/r1sh.py (it finds the R1's port by USB name).
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
export ADB_LIBUSB=0
wdt=${1:-600}
entry=0x$(grep ' kernel_entry$' "$here/out/System.map" | cut -c9-16)

adb push "$here/out/r1-linux.bin" /tmp/r1-linux.bin >/dev/null
adb push "$here/tools/stock-modules/r1jump/r1jump.ko" /tmp/r1jump.ko >/dev/null
echo "[$(date +%T)] pushed; entry $entry; waiting for the screen to be on"

# Stop the display controller before the jump, with r1player paused. Left
# scanning out stock's frame through the jump, it sometimes underran while
# r1jump copied the kernel and the new kernel started (about 1 boot in 13),
# and an underrun halts it for good: register 0x2004 reads 0x10f and
# nothing starts it again (docs/kernel.md, "Display"). Stopped, it is in the
# state a cold boot leaves it in; the screen stays dark until mainline's
# display driver starts it, about 1.5 s after the jump.
adb shell 'while [ "$(cat /sys/class/backlight/backlight_pwm0/brightness)" = 0 ]; do usleep 200000; done
  kill -STOP $(pidof r1player) 2>/dev/null; sync
  devmem 0x13052000 32 0x10
  i=0; while [ $(( $(devmem 0x13052004 32) & 1 )) = 1 ] && [ $i -lt 20 ]; do usleep 10000; i=$((i + 1)); done
  [ $(( $(devmem 0x13052004 32) & 1 )) = 0 ] || { echo "display did not stop: $(devmem 0x13052004 32)"; exit 1; }'

echo "[$(date +%T)] jumping (watchdog $wdt s)"
adb shell "insmod /tmp/r1jump.ko image=/tmp/r1-linux.bin load=0x80100000 entry=$entry wdt_secs=$wdt" &
# Mainline has its serial shell up about 3 s after the jump.
port=
for i in $(seq 1 20); do
	port=$(python3 -I "$here/tools/r1sh.py" --port) && break
	sleep 1
done
if [ -z "$port" ]; then
	echo "[$(date +%T)] no R1 serial port after 20 s"
	exit 1
fi
echo "[$(date +%T)] up on $port"
sleep 3
python3 -I "$here/tools/r1sh.py" 'dmesg'
