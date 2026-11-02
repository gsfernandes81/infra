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
# What this run's variant adds (run-late-disks.sh passes VARIANT): plain adds nothing;
# wantedby makes the stand-in service wanted by the mount unit as well; udev adds a rule that
# asks systemd for the mount when the array's btrfs reports ready.
case "${VARIANT:?}" in
plain) ;;
wantedby)
	mkdir -p /etc/systemd/system/media-array.mount.wants
	ln -sf /etc/systemd/system/sim-consumer.service \
		/etc/systemd/system/media-array.mount.wants/sim-consumer.service
	;;
udev)
	printf '%s\n' \
		"SUBSYSTEM==\"block\", ENV{ID_FS_UUID}==\"$uuid\", ENV{SYSTEMD_READY}!=\"0\", ENV{SYSTEMD_WANTS}+=\"media-array.mount\"" \
		> /etc/udev/rules.d/90-sim-array.rules
	cat /etc/udev/rules.d/90-sim-array.rules
	udevadm control --reload
	;;
*) echo "unknown VARIANT $VARIANT" >&2; exit 1 ;;
esac
systemctl daemon-reload
tail -n 1 /etc/fstab

# A container started by Docker's own restart policy, as the fleet's stacks are, with the
# array bind-mounted: systemd never starts it, so only Docker can bring it back.
mount /media/array
docker run -d --restart always --name simapp -v /media/array:/data \
	docker.io/library/alpine:3.20 sh -c 'cat /data/f && sleep 3600'
sleep 5
docker logs simapp
umount /media/array || { docker stop simapp; umount /media/array; docker start simapp; }
