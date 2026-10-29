#!/usr/bin/env bash
# One kernel attempt on the R1: build, put the card kernel on the card
# (card-install.sh), restart, wait for ADB, and report how long each
# stage took, which kernel came up, the kernel log lines that match, and,
# when the start stayed on the flash kernel, the failed boot's log (pstore).
#
#   R1_WHO=NAME tools/try.sh [--no-build] [--grep REGEX] [CMD]
#
# R1_WHO is this session's name in tools/r1lock.sh, whose lock it must hold
# or find free. CMD runs on the R1 afterwards (e.g. '/sbin/r1-wifi on').
# The card kernel stays on the card: card-install.sh --remove takes it off,
# back to the flash kernel alone (the normal setup).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
export ADB_LIBUSB=0
build=1
grep='mmc|sdio|brcm|wlan|cfg80211|error|fail|timeout'
while [ $# -gt 0 ]; do
	case "$1" in
	--no-build) build=0; shift ;;
	--grep) grep=$2; shift 2 ;;
	*) break ;;
	esac
done
cmd="${1:-}"
"$here/r1lock.sh" check "${R1_WHO:-}" || exit 1

r1() { timeout 20 adb shell "$1" < /dev/null | tr -d '\r'; }
t() { date +%s; }
start=$(t)
if [ $build = 1 ]; then
	"$here/../build.sh" | grep -v '^configuring$' || exit 1
	echo "== build: $(($(t) - start)) s"
fi
rel=$(cat "$here/../out/release")

s=$(t)
"$here/card-install.sh" --reboot
echo "== install: $(($(t) - s)) s"

# ADB goes away with the restart; wait for a shell that answers again.
s=$(t)
sleep 3
up=
for _ in $(seq 1 90); do
	if [ "$(timeout 3 adb shell echo up < /dev/null 2>/dev/null | tr -d '\r')" = up ]; then up=1; break; fi
	sleep 1
done
[ -n "$up" ] || { echo "== no ADB 90 s after the restart (serial: tools/r1sh.py)"; exit 1; }
total=$(($(t) - s))
kup=$(r1 "cut -d. -f1 /proc/uptime")
echo "== ADB back $total s after the restart; this kernel has been up $kup s"

now=$(r1 'uname -r')
if [ "$now" = "$rel" ]; then
	echo "== running the card kernel ($now)"
else
	echo "== STAYED ON $now, not $rel: the card kernel didn't come up. Its log:"
	r1 'tail -n 40 /sys/fs/pstore/console-ramoops-0 2>/dev/null || echo "(no pstore log)"'
	exit 1
fi
r1 "grep -q ' /mnt/sd_0 ' /proc/mounts && echo 'SD card: mounted' || echo 'SD card: NOT MOUNTED'"
echo "== kernel log (/$grep/):"
r1 "dmesg | grep -i -E '$grep'" | tail -n 40
if [ -n "$cmd" ]; then
	echo "== $cmd"
	r1 "$cmd"
fi
echo "== $(($(t) - start)) s in all"
