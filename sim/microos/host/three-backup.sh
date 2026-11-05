#!/bin/bash
# shellcheck disable=SC2016  # the checks are shell code for sh -c, quoted on purpose
# Runs on the simulated three as root between the steps of the backup stage in host/three.sh,
# which pushes from the runner as zero would, and prints PASS or FAIL per check. The stage
# names what to check: pushed, mirrored, confined, locked, after-lock.
set -u

check() {
	local name=$1 out
	shift
	if out=$("$@" 2>&1); then
		echo "PASS $name"
	else
		echo "FAIL $name"
		printf '%s\n' "$out" | tail -n 15 | sed 's/^/    /'
	fi
}
lib=/media/mirror/incoming/immich/library

case "${1:?stage}" in
pushed)
	check "the files are there, written by the backup user" sh -c "
		ls -ln $lib; [ \"\$(stat -c %U $lib/a.jpg)\" = backup ] && [ \"\$(cat $lib/b.jpg)\" = two ]"
	# fake super keeps "<mode in octal> <rdev major,minor> <uid>:<gid>" for a file it could
	# not chown.
	check "a.jpg keeps its real owner and mode as numbers, in rsync's xattr" sh -c "
		s=\$(python3 -c 'import os,sys; print(os.getxattr(sys.argv[1], \"user.rsync.%stat\").decode())' $lib/a.jpg); echo \"\$s\"
		[ \"\$s\" = '100640 0,0 1000:1000' ]"
	check "nothing half-written is left (--delay-updates)" sh -c "! find /media/mirror/incoming -name '.~tmp~' | grep ."
	;;
mirrored)
	check "a deletion on zero is mirrored, and a new file arrives" sh -c "
		ls $lib; [ ! -e $lib/b.jpg ] && [ -e $lib/c.jpg ] && [ -e $lib/a.jpg ]"
	;;
confined)
	# Calibration: the backup user can write to /tmp, so only the module stops the writes.
	check "the backup user may write to /tmp, so only the module can stop the writes" sh -c '
		runuser -u backup -- touch /tmp/sim-calibrate && rm /tmp/sim-calibrate'
	check "nothing was written to /tmp through the key" sh -c '
		ls /tmp/escape-* 2>/dev/null; ! ls /tmp/escape-* >/dev/null 2>&1'
	check "the symlinks it pushed are munged, so they lead nowhere" sh -c '
		for l in abs rel; do
			t=$(readlink "/media/mirror/incoming/link/$l" 2>/dev/null); echo "$l -> ${t:-absent}"
			[ -z "$t" ] || case "$t" in /rsyncd-munged/*) ;; *) exit 1 ;; esac
		done'
	check "the snapshots hold only dated snapshots" sh -c '
		ls /media/mirror/snapshots; ! ls /media/mirror/snapshots | grep -vE "^[0-9]{4}-[0-9]{2}-[0-9]{2}$"'
	rm -rf /media/mirror/incoming/link /media/mirror/incoming/escape*
	;;
locked)
	check "the array is locked, and incoming is not there to write to" sh -c '
		! findmnt /media/mirror && ! test -e /media/mirror/incoming'
	;;
after-lock)
	check "the push after the unlock arrived" sh -c "ls $lib; [ \"\$(cat $lib/d.jpg)\" = four ]"
	# The restore in hosts/three/leap/README.md: --fake-super reads the kept owners from the
	# source, and -M--super writes them for real at the destination.
	check "a restore puts back a.jpg's real owner and mode" sh -c "
		rm -rf /var/tmp/sim-restore
		rsync -aHAX --numeric-ids --fake-super -M--super $lib/ /var/tmp/sim-restore/
		s=\$(stat -c '%u:%g %a' /var/tmp/sim-restore/a.jpg); echo \"\$s\"; rm -rf /var/tmp/sim-restore
		[ \"\$s\" = '1000:1000 640' ]"
	;;
esac
