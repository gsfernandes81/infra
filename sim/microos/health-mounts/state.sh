#!/bin/bash
# Runs in the VM over ssh and prints what the health-mounts report compares: each data
# mount's state, what health-checker did this boot and the last, the snapshot, and what
# health-checker's own mount plugin answers now. Keeps going past a failed check.
set -u
run() { printf '$ %s\n' "$*"; "$@" 2>&1; printf '[exit %s]\n' "$?"; }

run cat /proc/uptime
run systemctl is-system-running
for m in sv svid whole bad; do
	run systemctl show -p ActiveState,SubState,Result "media-$m.mount"
done
run systemctl --failed --no-legend --no-pager
run sh -c 'btrfs subvolume get-default / | sed "s/.*path //"'
run sh -c 'journalctl -b -u health-checker -o short-monotonic --no-pager | tail -n 10'
echo "-- the previous boot:"
run sh -c 'journalctl -b -1 -u health-checker -o short-monotonic --no-pager 2>&1 | tail -n 10'
run sh -c 'journalctl -b -o short-monotonic --no-pager | grep -E "media-(sv|svid|whole|bad)\.mount|Timed out waiting for device" | tail -n 10'
run sh -c 'cat /var/lib/misc/health-check.state /var/lib/misc/health-check.rebooted 2>&1'
# What the plugin would say if health-checker ran now, after the device timeout.
run /usr/libexec/health-checker/btrfs-subvolumes-mounted.sh check
run sh -c 'journalctl --list-boots --no-pager | tail -n 4'
