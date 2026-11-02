#!/bin/bash
# Runs in the VM over ssh and prints the state the late-disks report compares: bcache,
# the btrfs array, the mount, the stand-in service and the bare mountpoint. Keeps going
# past a failed check.
set -u
run() { printf '$ %s\n' "$*"; "$@" 2>&1; printf '[exit %s]\n' "$?"; }

run systemctl is-system-running
run sh -c 'ls /sys/block | grep bcache'
run sh -c 'cat /sys/block/bcache*/bcache/state 2>&1'
run lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS
run btrfs filesystem show
run findmnt /media/array
run systemctl status media-array.mount --no-pager --lines 5
run systemctl status sim-consumer.service --no-pager --lines 5
run cat /run/sim-consumer.out
run sh -c 'journalctl -u media-array.mount -o short-precise --no-pager | tail -n 4'
# The guard is checked only while nothing is mounted, so a file written into the array
# itself is never mistaken for one that got past the bare mountpoint.
if findmnt -q /media/array; then
	echo "guard: not checked, the array is mounted"
elif touch /media/array/guard-failed 2>/dev/null; then
	echo "GUARD FAILED: wrote into the bare mountpoint"
	rm -f /media/array/guard-failed
else
	echo "guard: the bare mountpoint refused a write"
fi
run docker ps -a --filter name=simapp --format '{{.Names}} {{.Status}} restarts={{.RunningFor}}'
run docker inspect simapp --format 'restarts={{.RestartCount}} running={{.State.Running}}'
run sh -c 'docker logs simapp 2>&1 | tail -n 4'
