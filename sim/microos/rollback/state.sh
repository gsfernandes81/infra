#!/bin/bash
# Runs in the VM over ssh: which snapshot is booted and default, whether the stand-in
# runs, and what health-checker said this boot. Keeps going past a failed check.
set -u
run() { printf '$ %s\n' "$*"; "$@" 2>&1; printf '[exit %s]\n' "$?"; }
run sh -c 'snapper list --columns number,date,description | tail -n 6'
run sh -c 'btrfs subvolume get-default / | sed "s/.*path //"'
run sh -c 'grep -o "subvol=[^,]*" /proc/mounts | head -n 1'
run systemctl is-active sim-tunnel.service
run sh -c 'cat /usr/bin/sim-tunnel 2>&1 | head -n 3'
run sh -c 'journalctl -b -u health-checker --no-pager | tail -n 8'
echo "-- the previous boot, which is the one that rolled back when there was one:"
run sh -c 'journalctl -b -1 -u health-checker --no-pager 2>&1 | tail -n 8'
run sh -c 'cat /var/lib/misc/health-check.state /var/lib/misc/health-check.rebooted 2>&1'
run systemctl is-system-running
