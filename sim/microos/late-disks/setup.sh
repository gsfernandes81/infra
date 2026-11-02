#!/bin/bash
# Runs in the VM over ssh, on the first boot, with the three USB disks attached: builds
# zero's layout in miniature (one bcache cache in front of two backing disks, btrfs RAID1
# on the two bcache devices) and an fstab entry shaped as a MicroOS host's would be.
set -euxo pipefail

udevadm settle
lsblk -o NAME,SIZE,TRAN,MODEL
# The disks are told apart by their USB serials, which run-late-disks.sh sets.
cache=$(readlink -f /dev/disk/by-id/usb-*SIMCACHE*-0:0)
back0=$(readlink -f /dev/disk/by-id/usb-*SIMBACK0*-0:0)
back1=$(readlink -f /dev/disk/by-id/usb-*SIMBACK1*-0:0)

make-bcache -C "$cache"
make-bcache -B "$back0"
make-bcache -B "$back1"
udevadm settle
cset=$(bcache-super-show "$cache" | awk '/cset.uuid/ {print $2}')
for _ in $(seq 1 30); do
	[ -b /dev/bcache0 ] && [ -b /dev/bcache1 ] && break
	sleep 1
done
echo "$cset" > /sys/block/bcache0/bcache/attach
echo "$cset" > /sys/block/bcache1/bcache/attach
cat /sys/block/bcache0/bcache/state /sys/block/bcache1/bcache/state

mkfs.btrfs -q -L simarray -m raid1 -d raid1 /dev/bcache0 /dev/bcache1
udevadm settle
uuid=$(blkid -s UUID -o value /dev/bcache0)
mount -o context=system_u:object_r:container_file_t:s0 /dev/bcache0 /media/array
echo from-the-array > /media/array/f
umount /media/array

# nofail so a missing array never stops the boot; context= as the probe proved.
echo "UUID=$uuid /media/array btrfs nofail,context=system_u:object_r:container_file_t:s0 0 0" \
	>> /etc/fstab
systemctl daemon-reload
tail -n 1 /etc/fstab
