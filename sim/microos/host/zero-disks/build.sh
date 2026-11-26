#!/bin/bash
# Runs as root in the VM host/zero.sh's make_disks boots, with the three USB disks attached
# and the run's key file at /root/data.key: builds zero's disks as plans/zero-leap.md §
# The simulation describes them, with zero's own UUIDs, names and subvolume ids. STORE_ID is
# the id the Docker store's subvolume must get, the stand-in for fstab.append's placeholder.
#
# The SSD: p1 the bcache cache, p2 btrfs holding Alpine's Docker store and the new one, p3
# swap. The two hard disks: bcache backing devices on p1's cache set, unpartitioned as
# zero's are. LUKS2 data-luks-4 on one of the two bcache devices, opened by the key file,
# Adiantum as on zero. Then btrfs RAID1 over the other bcache device and data-4.
#
# Every filesystem is mounted with zero's context= while it is written, so no file is
# labelled here: the box under test must be the one that writes, or does not write, a label.
# Stops at the first failure; host/zero.sh then ends the run, as there is no box to check.
set -euxo pipefail
: "${STORE_ID:?}"
ctx=context=system_u:object_r:container_file_t:s0

udevadm settle
lsblk -o NAME,SIZE,TRAN,MODEL,SERIAL
# The disks are told apart by their USB serials, which host/zero.sh sets.
ssd=$(readlink -f /dev/disk/by-id/usb-*SIMSSD*-0:0)
back0=$(readlink -f /dev/disk/by-id/usb-*SIMBACK0*-0:0)
back1=$(readlink -f /dev/disk/by-id/usb-*SIMBACK1*-0:0)

sfdisk -q "$ssd" <<TABLE
label: gpt
size=2GiB, name=cache
size=24GiB, name=store
size=256MiB, name=swap
TABLE
udevadm settle
p1=${ssd}1 p2=${ssd}2 p3=${ssd}3

make-bcache -C "$p1"
make-bcache -B "$back0"
make-bcache -B "$back1"
udevadm settle
# Each backing disk's bcache device, read off the disk itself: which number each gets is
# the kernel's, as on zero, where nothing names either.
bcache_of() {
	local b i
	for i in $(seq 1 30); do
		b=$(lsblk -nro NAME,TYPE "$1" | awk '$1 ~ /^bcache/ { print $1; exit }')
		[ -n "$b" ] && { echo "/dev/$b"; return 0; }
		sleep 1
	done
	echo "no bcache device on $1" >&2
	return 1
}
plain=$(bcache_of "$back0")
under=$(bcache_of "$back1")
cset=$(bcache-super-show "$p1" | awk '/cset.uuid/ { print $2 }')
for b in "$plain" "$under"; do
	echo "$cset" > "/sys/block/${b#/dev/}/bcache/attach"
	cat "/sys/block/${b#/dev/}/bcache/state" "/sys/block/${b#/dev/}/bcache/cache_mode"
done

cryptsetup luksFormat --batch-mode --type luks2 --cipher xchacha12,aes-adiantum-plain64 \
	--key-size 256 --label data-luks-4 --uuid c00f99a6-20ba-4fdc-af80-b6fde37131f1 \
	--key-file /root/data.key "$under"
cryptsetup open --key-file /root/data.key "$under" data-4

mkfs.btrfs -q -f -L data -U 813c830a-0892-41e8-b39b-32d661c79e2c -m raid1 -d raid1 \
	"$plain" /dev/mapper/data-4
udevadm settle
mount -o "$ctx" /dev/mapper/data-4 /mnt
# Subvolume ids are handed out in order from 256 and never reused, so fillers take the ids
# below zero's: 278 media-syncthing, 279 and 280 the old Immich subvolumes, 281 immich, with
# data/thumbs, data/encoded-video and .snapshots nested in it at 282 to 284, as the paste
# from zero showed (plans/zero-leap.md). The fillers stay; nothing names them.
for i in $(seq 256 277); do btrfs subvolume create "/mnt/filler-$i" > /dev/null; done
btrfs subvolume create /mnt/media-syncthing
btrfs subvolume create /mnt/old-immich-279 /mnt/old-immich-280
btrfs subvolume create /mnt/immich
mkdir /mnt/immich/data /mnt/immich/db
btrfs subvolume create /mnt/immich/data/thumbs
btrfs subvolume create /mnt/immich/data/encoded-video
btrfs subvolume create /mnt/immich/.snapshots
# Each a marker the box's checks read through a container; Syncthing's data is 1000's.
echo marker > /mnt/media-syncthing/marker
chown -R 1000:1000 /mnt/media-syncthing
echo marker > /mnt/immich/marker
btrfs subvolume list /mnt
id_of() { btrfs subvolume list /mnt | awk -v p="$1" '$NF == p { print $2 }'; }
[ "$(id_of media-syncthing)" = 278 ] && [ "$(id_of immich)" = 281 ] &&
	[ "$(id_of immich/.snapshots)" = 284 ]
umount /mnt
cryptsetup close data-4

mkfs.btrfs -q -f -U 7bebb62b-62b1-444c-a602-38d11022781a "$p2"
mount -o "$ctx" "$p2" /mnt
btrfs subvolume create /mnt/var-lib-docker
btrfs subvolume create /mnt/var-lib-docker-leap
btrfs subvolume list /mnt
[ "$(btrfs subvolume list /mnt | awk '$NF == "var-lib-docker-leap" { print $2 }')" = "$STORE_ID" ]
umount /mnt

mkswap -q -U eedeca9c-13a8-483b-bee7-8467869ec91a "$p3"
sync
echo "zero's disks are built"
