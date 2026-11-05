# shellcheck shell=bash
# The steps every Leap host's first-boot script shares; sourced by
# hosts/<host>/leap/combustion/script, never run on its own. leap/README.md says how the
# stick is made and what each part of it holds.
#
# Combustion runs the host's script once, at first boot, inside a transactional-update
# shell, and boots straight into the snapshot it leaves. It copies only the stick's
# combustion/ directory, unmounts the stick, and runs the script from the copy, so
# everything the script reads lives under combustion/: this library, the host's files and
# the carry-over. Every write to the root filesystem happens here or never, because the root is
# read-only afterwards. A failed command stops the script, and Combustion then leaves the
# image unconfigured rather than half-configured: set -e in the host's script is the point.
#
# THE SHELL MOUNTS LESS THAN IT SEEMS. transactional-update's shell binds /root, /var/log
# and a few /var paths into the new snapshot, and not /home or /usr/local: a write there
# lands in the snapshot's own directory, under the subvolume that covers it at boot, and is
# never seen. The first simulated boot lost gavin's home and both pinned binaries that way.
# So mount_subvolumes mounts them first, and label_subvolumes labels what was written,
# since this runs before the SELinux policy is loaded and the boot's relabel skips them.
#
# Nothing here is generated: each file it installs is a reviewed file from the repo,
# installed at the path its own infra- header names, or a carry-over file copied verbatim.

# The pins for binaries a distro package would get wrong, in leap/pins, which the update
# play reads too (server-update-leap.yml): what a new host starts on, and what the play
# moves a running one to. aarch64 is the Pi's; x86_64 exists for the simulation
# (sim/microos/run-host.sh), which boots this script in a VM.
# shellcheck source=leap/pins
. ./leap/pins
case "$(uname -m)" in
aarch64)
	cloudflared_asset=cloudflared-linux-arm64
	cloudflared_sha256=$cloudflared_sha256_aarch64
	compose_asset=docker-compose-linux-aarch64
	compose_sha256=$compose_sha256_aarch64
	;;
x86_64)
	cloudflared_asset=cloudflared-linux-amd64
	cloudflared_sha256=$cloudflared_sha256_x86_64
	compose_asset=docker-compose-linux-x86_64
	compose_sha256=$compose_sha256_x86_64
	;;
*)
	echo "firstboot: no pins for $(uname -m)" >&2
	exit 1
	;;
esac

# The packages every host carries. openSUSE's docker-compose is locked out rather than
# left as a recommendation of docker's: the host runs upstream's, and a lock also stops a
# later update pulling it back in.
common_packages=(docker docker-buildx smartmontools btrfsprogs fish htop nano curl jq git
	python3 rsync tailscale zram-generator)

say() { echo "firstboot: $*" > /dev/console; echo "firstboot: $*"; }
die() { say "STOPPED: $*"; exit 1; }

# Combustion's copy of the stick's combustion/ directory, which the script runs from.
stick=$PWD

mount_subvolumes() {
	local d
	for d in /home /usr/local; do
		findmnt -n "$d" >/dev/null || mount "$d"
	done
}

label_subvolumes() {
	local policy
	policy=$(sed -n 's/^SELINUXTYPE=//p' /etc/selinux/config)
	setfiles -F "/etc/selinux/$policy/contexts/files/file_contexts" /home /usr/local /root
}

# Installs one tracked file at the path and mode its infra- header declares, the header the
# repo's tools read (bin/_infra.py). A file without a full header stops the script.
install_tracked() {
	local file=$1 path name mode
	path=$(sed -n 's/^# infra-path:[[:space:]]*//p' "$file")
	name=$(sed -n 's/^# infra-name:[[:space:]]*//p' "$file")
	mode=$(sed -n 's/^# infra-mode:[[:space:]]*//p' "$file")
	[ -n "$path" ] && [ -n "$name" ] && [ -n "$mode" ] || die "$file has no full infra- header"
	install -D -m "$mode" "$file" "$path/$name"
	# sudo refuses to run at all over one bad file in sudoers.d, which would leave only the
	# console to elevate on.
	if [ "$path" = /etc/sudoers.d ]; then
		visudo -cf "$path/$name" >/dev/null || die "$file is not valid sudoers"
	fi
}

# Downloads a pinned binary and installs it only if its SHA-256 matches.
install_pinned() {
	local url=$1 sha256=$2 dest=$3 tmp
	tmp=$(mktemp)
	curl -fsSL -o "$tmp" "$url" || die "could not download $url"
	echo "$sha256  $tmp" | sha256sum -c - >/dev/null || die "SHA-256 mismatch for $url"
	install -D -m 0755 "$tmp" "$dest"
	rm -f "$tmp"
}

# Refuses to start on a stick without the carry-over a host cannot run without, so a
# forgotten file stops the first boot instead of leaving a box nobody can log in to.
check_carry() {
	local host=$1 f
	for f in shadow/root shadow/gavin gavin/authorized_keys \
		ssh/ssh_host_ed25519_key ssh/ssh_host_ed25519_key.pub; do
		[ -s "$stick/carry/$f" ] || die "carry/$f is missing or empty"
	done
	# A host with a tunnel config must carry the tunnel's credentials. A new host has
	# neither: its tunnel is made after its first boot (make-stick --new).
	if [ -e "$stick/host/system/cloudflared-config.yml" ]; then
		[ -s "$stick/carry/cloudflared/$host.json" ] || die "carry/cloudflared/$host.json is missing or empty"
	fi
	for f in shadow/root shadow/gavin; do
		grep -q '^\$' "$stick/carry/$f" || die "carry/$f is not a password hash"
	done
}

# The console's way in: a password for root, which sulogin needs in emergency mode, and
# never an ssh key for it (decisions.md § MicroOS hosts have a root password).
set_root_password() {
	printf 'root:%s\n' "$(cat "$stick/carry/shadow/root")" | chpasswd -e
}

# gavin keeps his Alpine uid and gid, so files he owns on the data disks stay his.
make_gavin() {
	local uid=$1 gid=$2
	groupadd -g "$gid" gavin
	useradd -m -u "$uid" -g gavin -s /usr/bin/fish -c gavin gavin
	printf 'gavin:%s\n' "$(cat "$stick/carry/shadow/gavin")" | chpasswd -e
	install -d -m 700 -o gavin -g gavin /home/gavin/.ssh
	install -m 600 -o gavin -g gavin "$stick/carry/gavin/authorized_keys" \
		/home/gavin/.ssh/authorized_keys
}

# The old host's ssh host keys, so every client's pinned known_hosts entry still matches.
install_host_keys() {
	local f
	for f in "$stick"/carry/ssh/ssh_host_*_key; do
		install -m 600 "$f" "/etc/ssh/$(basename "$f")"
		install -m 644 "$f.pub" "/etc/ssh/$(basename "$f").pub"
	done
}

# Tailscale's repository, trusted through the reviewed copy of its key, then every package.
# The repository goes in first: the first simulated boot added it with the other /etc
# files, after the packages, and got openSUSE's tailscale.
install_packages() {
	install_tracked "$stick/host/system/tailscale.repo"
	rpm --import "$stick/leap/tailscale-repo.gpg"
	zypper --non-interactive addlock docker-compose
	# The Pi's boot chain, which lives on the FAT boot partition outside every snapshot, so a
	# rollback cannot undo a bad update to it (docs/decisions.md § The Pi's boot firmware is
	# locked). Locked by name, so the lock holds on an image that ships none of them, as the
	# simulation's x86 one does.
	zypper --non-interactive addlock 'u-boot-rpi*' 'raspberrypi-firmware*' 'raspberrypi-eeprom*'
	zypper --non-interactive refresh
	zypper --non-interactive install "${common_packages[@]}" "$@"
}

install_binaries() {
	install_pinned \
		"https://github.com/cloudflare/cloudflared/releases/download/$cloudflared_version/$cloudflared_asset" \
		"$cloudflared_sha256" /usr/local/bin/cloudflared
	install_pinned \
		"https://github.com/docker/compose/releases/download/v$compose_version/$compose_asset" \
		"$compose_sha256" /usr/local/lib/docker/cli-plugins/docker-compose
}

# The units every host runs, the reboot policy, and the two ways in kept in rescue mode
# (decisions.md § Rescue mode keeps a way in on every Leap host).
enable_units() {
	systemctl enable sshd.service docker.service cloudflared.service tailscaled.service
	# Masked, not disabled: systemd applies the image's presets on a first boot, and Leap's
	# enable this timer, so a disable here was undone at the first start.
	systemctl mask transactional-update.timer
	# systemd-user-sessions as well: rescue mode would otherwise stop it, its stop writes
	# /run/nologin, and that refuses every login but root's, which sshd refuses anyway.
	systemctl add-wants rescue.target sshd.service NetworkManager.service \
		cloudflared.service tailscaled.service systemd-user-sessions.service
	# Leap's first-boot wizard waits at a console nobody watches and powers the box off if
	# it fails. A successful Combustion run already keeps it away; the mask is in case.
	systemctl mask jeos-firstboot.service
}

# The update recipes, at every login (leap/motd): the normal update, and the boot firmware's,
# which is locked. A plain file, so it carries no infra- header for logins to show; the
# update play installs it afresh at every run.
install_motd() {
	install -D -m 644 "$stick/leap/motd" /etc/motd.d/50-infra-updates
}

# The repo's checkout, as on every host, and each deployment's .env and secrets directory
# from the carry-over.
clone_infra() {
	local f name
	git clone --quiet https://github.com/gsfernandes81/infra.git /home/gavin/infra
	for f in "$stick"/carry/env/*.env; do
		[ -e "$f" ] || continue
		name=$(basename "$f" .env)
		[ -d "/home/gavin/infra/deployments/$name" ] || die "carry/env/$name.env has no deployment"
		install -m 600 "$f" "/home/gavin/infra/deployments/$name/.env"
	done
	chown -R gavin:gavin /home/gavin/infra
	# Each deployment's secrets directory, as its play left it in gavin's home.
	for f in "$stick"/carry/home/.*-secrets; do
		[ -d "$f" ] || continue
		cp -a "$f" /home/gavin/
		chown -R gavin:gavin "/home/gavin/$(basename "$f")"
	done
}

# Named volumes cannot be restored here, with no Docker running, so their tar files wait in
# root's home for the runbook's restore, and leave the stick that is about to be erased.
keep_volume_tars() {
	local f
	for f in "$stick"/carry/volumes/*.tar; do
		[ -e "$f" ] || continue
		install -D -m 600 "$f" "/root/volumes/$(basename "$f")"
	done
}
