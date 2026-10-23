#!/bin/sh
# Jump into the mainline kernel on the SD card (docs/kernel.md, "Mainline on
# the R1"), from the stock kernel, before r1player starts. Returns only when
# it doesn't jump; hiby_player.sh then carries on with the stock system.
#
# It stays on stock when:
#   - /.r1-mainline/ on the card lacks the kernel, r1jump.ko or its entry,
#   - a .no-mainline file exists at the card root, or there is no card,
#   - mainline failed twice in a row: a watchdog reset after a jump counts as
#     one failure, and a power-on clears the count.
# No key is read: Next held while the R1 starts puts the X1600 in its USB
# boot mode instead (docs/kernel.md, "Boot chain").
#
#   r1-mainline.sh SD_MOUNT_POINT

SD=$1
MAIN=$SD/.r1-mainline
STATE=/usr/data/r1player
JUMPED=$STATE/mainline-jumped
FAILS=$STATE/mainline-fails

# CPM RSR: bit 0 power-on, bit 1 watchdog. A power-on clears it and a
# watchdog reset adds its bit to what is there, so clear it after each read.
rsr=$(devmem 0x10000008 32)
devmem 0x10000008 32 0
fails=$(cat $FAILS 2>/dev/null)
fails=${fails:-0}
if [ $(( rsr & 1 )) = 1 ]; then
	fails=0
elif [ -e $JUMPED ] && [ $(( rsr & 2 )) = 2 ]; then
	fails=$((fails + 1))
fi
mkdir -p $STATE
rm -f $JUMPED
echo $fails > $FAILS
echo "$(date) rsr $rsr, mainline failures $fails"

[ -f $MAIN/r1-linux.bin ] && [ -f $MAIN/r1jump.ko ] && [ -f $MAIN/entry ] || exit 0
[ ! -e $SD/.no-mainline ] || exit 0
[ $fails -lt 2 ] || { echo "mainline failed twice: staying on stock"; exit 0; }

# The stock kernel lights the screen at boot; give it 10 s.
i=0
while [ "$(cat /sys/class/backlight/backlight_pwm0/brightness)" = 0 ]; do
	[ $i -lt 50 ] || { echo "screen never came on: staying on stock"; exit 0; }
	usleep 200000
	i=$((i + 1))
done

# Stop the display controller first: left scanning out through the jump, it
# sometimes halts for good after an underrun (as in kernel/tools/boot.sh).
devmem 0x13052000 32 0x10
i=0
while [ $(( $(devmem 0x13052004 32) & 1 )) = 1 ] && [ $i -lt 20 ]; do
	usleep 10000
	i=$((i + 1))
done

echo "$(date) jumping to mainline"
touch $JUMPED
sync
# r1jump's watchdog brings the R1 back if mainline dies before its own
# watchdog driver takes over; insmod only returns if the jump failed.
insmod $MAIN/r1jump.ko image=$MAIN/r1-linux.bin load=0x80100000 \
	entry=$(cat $MAIN/entry) wdt_secs=20
echo "$(date) the jump failed: staying on stock"
rm -f $JUMPED
# Restart the display on the descriptor the stock kernel left: nothing on
# the stock side does (r1player's page flips don't).
devmem 0x13051004 32 1
exit 0
