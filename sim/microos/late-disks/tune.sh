#!/bin/bash
# Runs in the VM over ssh after the first late-disk stages: gives the array's fstab entry a
# longer device timeout, and adds a udev rule that asks systemd for the mount whenever a
# member of the array appears. The next stages show what each one changes.
set -euxo pipefail

uuid=$(findmnt -no UUID /media/array)
sed -i "s#^UUID=$uuid /media/array btrfs nofail,#UUID=$uuid /media/array btrfs nofail,x-systemd.device-timeout=180s,#" /etc/fstab
grep /media/array /etc/fstab
cat > /etc/udev/rules.d/90-sim-array.rules <<RULE
# Starts the array's mount when its btrfs reports ready, so an array that arrives after
# boot is mounted without hands. btrfs's own rule holds SYSTEMD_READY at 0 until every
# member is present.
SUBSYSTEM=="block", ENV{ID_FS_UUID}=="$uuid", ENV{SYSTEMD_READY}!="0", ENV{SYSTEMD_WANTS}+="media-array.mount"
RULE
cat /etc/udev/rules.d/90-sim-array.rules
systemctl daemon-reload
udevadm control --reload
