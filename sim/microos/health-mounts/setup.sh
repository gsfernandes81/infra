#!/bin/bash
# Runs in the VM over ssh, on the first boot, with the data disk attached: makes a btrfs
# with one subvolume and mounts it three ways, as the fleet's fstabs do (one's uses both
# subvol= and subvolid=; zero's subvolid=), each with nofail and the 180 s device timeout
# the hosts will carry.
set -euxo pipefail

udevadm settle
data=$(readlink -f /dev/disk/by-id/usb-*SIMDATA*-0:0)
mkfs.btrfs -q -f -L simdata "$data"
udevadm settle
uuid=$(blkid -s UUID -o value "$data")
mount "$data" /mnt
btrfs subvolume create /mnt/data
id=$(btrfs subvolume show /mnt/data | awk '/Subvolume ID:/ {print $3}')
echo in-the-subvolume > /mnt/data/f
umount /mnt

opts="nofail,x-systemd.device-timeout=180s,context=system_u:object_r:container_file_t:s0"
cat >> /etc/fstab <<FSTAB
UUID=$uuid /media/sv btrfs $opts,subvol=data 0 0
UUID=$uuid /media/svid btrfs $opts,subvolid=$id 0 0
UUID=$uuid /media/whole btrfs $opts 0 0
FSTAB
tail -n 3 /etc/fstab
systemctl daemon-reload
mount -a
findmnt -t btrfs -o TARGET,OPTIONS | grep /media
