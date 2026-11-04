# shellcheck shell=bash
# shellcheck disable=SC2034,SC2054  # read by run-host.sh; commas belong to qemu
# one's stand-ins for sim/microos/run-host.sh; sourced, never run.

# What each FILL-FROM-ONE placeholder still in one's files would become in the simulation.
# None is left: every value is one's own, read off the box on 2026-11-03, and make_disks
# below gives the subvolumes the ids one's fstab names.
declare -A standin=()

# qemu's user network on one's own subnet, so its static address answers.
sim_net=192.168.86.0/24
sim_gateway=192.168.86.1
# qemu's own resolver; the guest's static profile names public ones, which qemu also reaches.
sim_dns=192.168.86.3
sim_address=192.168.86.101
# The first address qemu's DHCP hands out.
sim_dhcp_address=192.168.86.15

tunnel_id=1e7fde2e-ac2f-4a5e-8ad4-591208c1e2a6

# A stand-in value for each name a deployment's compose.yaml requires, for its .env: the
# paths are the ones one's real .env files name, so the deploy play's plan reads real
# mountpoints; secrets are made up for the run.
standin_env() {
	local dep=$1 name=$2
	case "$name" in
	TUNNEL_CREDENTIALS) echo "/home/gavin/.$dep-secrets/tunnel.json" ;;
	TUNNEL_ID) echo "00000000-0000-4000-8000-$(printf '%012d' "${#dep}")" ;;
	CALIBRE_CONFIG) echo /media/calibre/config ;;
	CALIBRE_LIBRARY) echo /media/calibre/library ;;
	PUID | PGID) echo 1000 ;;
	TZ) echo Europe/London ;;
	SRC_ROOT) echo /home/gavin/src ;;
	PUBLIC_BASE_URL) echo "https://$dep.sim.invalid" ;;
	*) openssl rand -hex 16 ;;
	esac
}

# What a first real deploy creates before the play can plan, and --check never does:
# garmin-mcp's upstream source, at SOURCE's sha, where its preflight hook would put it.
sim_before_deploy() {
	local url sha
	read -r url sha < <(grep -vE '^\s*(#|$)' "$repo/deployments/garmin-mcp/SOURCE" | head -n 1)
	ssh_as gavin@127.0.0.1 bash -s <<STEP 2>&1 || echo "FAIL could not check out garmin-mcp's source"
set -e
mkdir -p ~/src
git clone -q '$url' ~/src/garmin-mcp
git -C ~/src/garmin-mcp checkout -q '$sha'
STEP
}
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
	for n in media-ionic-mysql media-torrents media-torrents-config media-syncthing-config media-calibre-library \
		media-calibre-config var-lib-docker var-lib-docker-leap; do
		sudo btrfs subvolume create "$m/$n" >/dev/null
	done
	echo marker | sudo tee "$m/media-torrents/marker" >/dev/null
	sudo chown 1000:1000 "$m/media-torrents/marker"
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
