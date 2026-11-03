# shellcheck shell=bash
# shellcheck disable=SC2034,SC2054  # read by run-host.sh; commas belong to qemu
# one's stand-ins for sim/microos/run-host.sh; sourced, never run.

# What each FILL-FROM-ONE placeholder becomes in the simulation. The subvolume ids are the
# ones make_disks below produces; the real values come from one itself.
declare -A standin=(
	[FILL-FROM-ONE-gavin-uid]=1000
	[FILL-FROM-ONE-gavin-gid]=1000
	[FILL-FROM-ONE-calibre-library]=260
	[FILL-FROM-ONE-calibre-config]=261
	[FILL-FROM-ONE-var-lib-docker-leap]=263
	[FILL-FROM-ONE-prefix]=24
	[FILL-FROM-ONE-gateway]=192.168.86.1
	[FILL-FROM-ONE-dns]=192.168.86.3
	[FILL-FROM-ONE-ipv6]=disabled
	[FILL-FROM-ONE-garmin-tokens-volume]=garmin-mcp_garmin-tokens
)

# qemu's user network on one's own subnet, so its static address answers.
sim_net=192.168.86.0/24
sim_gateway=192.168.86.1
sim_dns=192.168.86.3
sim_address=192.168.86.101

tunnel_id=1e7fde2e-ac2f-4a5e-8ad4-591208c1e2a6
deployments=(calibre-web garmin-mcp send2ereader torrents)
volumes=(garmin-mcp_garmin-tokens)

# The SSD as Alpine left it: one btrfs with one's filesystem UUID and its subvolumes made in
# the order that gives the fstab's ids (256 to 259, then calibre's two, Alpine's Docker
# store, and the new empty one), unlabelled as Alpine leaves them; and the swap partition,
# here a disk of its own, with its UUID. Both on USB, as one's SSD is.
make_disks() {
	local m
	truncate -s 4G ssd.img
	mkfs.btrfs -q -f -U adc3a286-d7c1-4fef-885f-b3ca6f790a86 ssd.img
	m=$(mktemp -d)
	sudo mount -o loop ssd.img "$m"
	for n in ionic-mysql torrents torrents-config syncthing-config media-calibre-library \
		media-calibre-config var-lib-docker var-lib-docker-leap; do
		sudo btrfs subvolume create "$m/$n" >/dev/null
	done
	echo marker | sudo tee "$m/torrents/marker" >/dev/null
	sudo chown 1000:1000 "$m/torrents/marker"
	sudo btrfs subvolume list "$m"
	sudo umount "$m"
	rmdir "$m"
	truncate -s 256M swap.img
	mkswap -q -U d2bb5b47-1a76-40a0-8b37-1dad005dc7c9 swap.img
}
disk_args=(
	-drive file="$PWD/ssd.img",if=none,id=ssd,format=raw
	-device usb-storage,bus=xhci.0,drive=ssd
	-drive file="$PWD/swap.img",if=none,id=swap,format=raw
	-device usb-storage,bus=xhci.0,drive=swap
)
