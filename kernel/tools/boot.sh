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

# The display controller rereads its frame descriptor every frame, and the
# stock kernel allocates it anywhere (it moves when r1player flips pages).
# With r1player paused, chain it to a self-linked copy showing page 0 in
# the last row of framebuffer page 1 (0x02776f00): memory the stock kernel
# owns and won't hand out (r1jump once overwrote a page it thought free),
# and which the mainline device tree reserves.
adb shell 'while [ "$(cat /sys/class/backlight/backlight_pwm0/brightness)" = 0 ]; do usleep 200000; done
  kill -STOP $(pidof r1player) 2>/dev/null; sync
  d=$(devmem 0x13051000 32); new=$((0x02776f00))
  i=0; while [ $i -lt 16 ]; do devmem $((new + i * 4)) 32 $(devmem $((d + i * 4)) 32); i=$((i + 1)); done
  devmem $new 32 $new
  devmem $((new + 4)) 32 0x02600000
  devmem $d 32 $new
  usleep 50000
  [ "$(devmem 0x13051000 32)" = 0x02776F00 ] || { echo "display did not take the new descriptor"; exit 1; }'

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
