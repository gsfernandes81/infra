#!/bin/bash
# Runs in the VM over ssh after the first late-disk stages: gives the array's fstab entry a
# 180 s device timeout, longer than systemd's default 90 s, so the next stage can plug the
# disks in between the two.
set -euxo pipefail

uuid=$(findmnt -no UUID /media/array)
sed -i "s#^UUID=$uuid /media/array btrfs nofail,#UUID=$uuid /media/array btrfs nofail,x-systemd.device-timeout=180s,#" /etc/fstab
grep /media/array /etc/fstab
systemctl daemon-reload
