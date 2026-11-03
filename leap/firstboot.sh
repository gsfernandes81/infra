# shellcheck shell=bash
# The steps every Leap host's first-boot script shares; sourced by
# hosts/<host>/leap/combustion/script, never run on its own. leap/README.md says how the
# stick is made and what each part of it holds.
#
# Combustion runs the host's script once, at first boot, inside a transactional-update
# shell, and boots straight into the snapshot it leaves. It copies only the stick's
# combustion/ directory, unmounts the stick, and runs the script from the copy, so
# everything the script reads lives under combustion/: this library, the host's files and
# the carry-over. Before the script runs, it mounts the image's own fstab inside the new
# root, so /home, /var and /usr/local are writable here. Every write to the root filesystem happens here or never, because the root is
# read-only afterwards. A failed command stops the script, and Combustion then leaves the
# image unconfigured rather than half-configured: set -e in the host's script is the point.
#
# Nothing here is generated: each file it installs is a reviewed file from the repo,
# installed at the path its own infra- header names, or a carry-over file copied verbatim.

# The pins for binaries a distro package would get wrong (docs/decisions.md § Every box has
# two ways in, § Leap hosts carry upstream's Compose). After first boot the monthly update
# play moves them on the host; these are only what a new host starts on. aarch64 is the
# Pi's; x86_64 exists for the simulation (sim/microos/run-host.sh), which boots this script
# in a VM.
cloudflared_version=2026.10.7
compose_version=5.6.1
case "$(uname -m)" in
aarch64)
	cloudflared_asset=cloudflared-linux-arm64
	cloudflared_sha256=3df43aedc9ff291d1735b5cb576cb97e0b157488796db2e32b28aecabb445775
	compose_asset=docker-compose-linux-aarch64
	compose_sha256=42cfa75f51ad0ccf290bad37899e0038a8c10a0069e85233ecc1d53e3ff1347d
	;;
x86_64)
	cloudflared_asset=cloudflared-linux-amd64
	cloudflared_sha256=1f99fb518b83dec2ba8d870a7cc991d82a77e6196295a3d2754ba17ab9f91872
	compose_asset=docker-compose-linux-x86_64
	compose_sha256=47737f4236e6d3ccea7291995203f8f018058783b4c3a9469119811a0b5db8c0
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
	python3 rsync tailscale)

say() { echo "firstboot: $*" > /dev/console; echo "firstboot: $*"; }
die() { say "STOPPED: $*"; exit 1; }

# Combustion's copy of the stick's combustion/ directory, which the script runs from.
stick=$PWD

# Installs one tracked file at the path and mode its infra- header declares, the header the
# repo's tools read (bin/_infra.py). A file without a full header stops the script.
install_tracked() {
	local file=$1 path name mode
	path=$(sed -n 's/^# infra-path:[[:space:]]*//p' "$file")
	name=$(sed -n 's/^# infra-name:[[:space:]]*//p' "$file")
	mode=$(sed -n 's/^# infra-mode:[[:space:]]*//p' "$file")
	[ -n "$path" ] && [ -n "$name" ] && [ -n "$mode" ] || die "$file has no full infra- header"
	install -D -m "$mode" "$file" "$path/$name"
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
	for f in shadow/root shadow/gavin gavin/authorized_keys "cloudflared/$host.json" \
		ssh/ssh_host_ed25519_key ssh/ssh_host_ed25519_key.pub; do
		[ -s "$stick/carry/$f" ] || die "carry/$f is missing or empty"
	done
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
install_packages() {
	rpm --import "$stick/leap/tailscale-repo.gpg"
	zypper --non-interactive addlock docker-compose
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
	systemctl disable transactional-update.timer
	# systemd-user-sessions as well: rescue mode would otherwise stop it, its stop writes
	# /run/nologin, and that refuses every login but root's, which sshd refuses anyway.
	systemctl add-wants rescue.target sshd.service NetworkManager.service \
		cloudflared.service tailscaled.service systemd-user-sessions.service
	# Leap's first-boot wizard waits at a console nobody watches and powers the box off if
	# it fails. A successful Combustion run already keeps it away; the mask is in case.
	systemctl mask jeos-firstboot.service
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
