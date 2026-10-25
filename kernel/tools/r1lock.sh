#!/usr/bin/env bash
# Who has the R1: one lock on this Mac that every session checks before it
# uses the R1 over ADB or serial, instead of asking the others.
#
#   tools/r1lock.sh take WHO MINUTES WHAT   take it (or extend your own);
#                                           fails, naming the holder, while
#                                           someone else's hasn't expired
#   tools/r1lock.sh release WHO             give it back
#   tools/r1lock.sh check [WHO]             0 if it's free or WHO's
#   tools/r1lock.sh status                  who has it, until when, for what
#
# WHO is the session's name as other sessions see it. A lock nobody
# released expires after MINUTES, so a session that died doesn't keep it.
set -euo pipefail
lock=/tmp/hiby-r1.lock
now=$(date +%s)

# holder, expiry (seconds), what; empty when free or expired
read_lock() {
	holder= until=0 what=
	[ -f $lock ] || return 0
	{ read -r holder; read -r until; read -r what; } < $lock || true
	[ "$until" -gt "$now" ] 2>/dev/null || holder=
}

describe() {
	echo "$holder has the R1 until $(date -r "$until" +%H:%M 2>/dev/null || date -d "@$until" +%H:%M): $what"
}

# One r1lock.sh at a time between reading the lock and writing it; a
# mutex left by one that was killed goes after 5 s.
for _ in $(seq 50); do mkdir $lock.d 2>/dev/null && break; sleep 0.1; done
mkdir -p $lock.d
trap 'rmdir $lock.d 2>/dev/null' EXIT

read_lock
case "${1:-}" in
take)
	[ $# = 4 ] || { echo "usage: r1lock.sh take WHO MINUTES WHAT"; exit 2; }
	if [ -n "$holder" ] && [ "$holder" != "$2" ]; then
		describe
		exit 1
	fi
	# Written whole and renamed, so a reader never sees half a lock.
	printf '%s\n%s\n%s\n' "$2" $((now + $3 * 60)) "$4" > $lock.$$
	mv $lock.$$ $lock
	read_lock
	describe
	;;
release)
	[ $# = 2 ] || { echo "usage: r1lock.sh release WHO"; exit 2; }
	if [ -n "$holder" ] && [ "$holder" != "$2" ]; then
		describe
		exit 1
	fi
	rm -f $lock
	echo "R1 free"
	;;
check)
	[ -z "$holder" ] || [ "$holder" = "${2:-}" ] || { describe; exit 1; }
	;;
status)
	if [ -n "$holder" ]; then describe; else echo "R1 free"; fi
	;;
*)
	sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
	exit 2
	;;
esac
