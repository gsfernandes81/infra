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
# read-only afterwards.
#
# A FAILED RUN IS ONLY HALF UNDONE. A failed command stops the script (set -e in the host's
# script), and Combustion rolls the new snapshot back, so /etc, the packages and the rest of
# the snapshot are dropped. What the script wrote outside the snapshot stays: /home and
# /usr/local, through the mounts below, /root and /var/log, which the shell binds, /var's
# subvolume where install_tailscale_state writes, and the FAT boot partition. And a first
# boot that stops before it is committed runs Combustion again at the next boot while its
# config is still there, over a snapshot this script may have finished (leap/README.md
# § What the November visit's first boots taught). So every step checks what it would
# create and skips it when it is there, or refuses when what is there is not what it would
# make, and running the script again finishes the box rather than stopping at the first
# thing it finds.
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
	python3 rsync tailscale zram-generator make)

say() { echo "firstboot: $*" > /dev/console; echo "firstboot: $*"; }
die() { say "STOPPED: $*"; exit 1; }

# Everything the script prints also goes to /var/log/infra-firstboot.log. transactional-update's
# shell binds the real /var/log into the snapshot it builds, so the log outlives a failed run,
# whose snapshot Combustion throws away along with the initramfs's own journal. A box that
# stops at its first boot, with no screen to hand, is read by a raw search of its card for
# "firstboot:" (leap/README.md § What the first boot does). Found at the visit, when one's
# first boot stopped without a trace.
mkdir -p /var/log
exec > >(tee -a /var/log/infra-firstboot.log) 2>&1

# A Pi has no clock of its own: it boots at whatever date its software was built, and
# nothing sets the time inside the initramfs, where this runs. Months behind, every HTTPS
# certificate the downloads meet reads "not yet valid". So the time is read first from a plain
# HTTP answer's Date header, which needs no certificate. A VM has its host's clock, which is
# why the simulation never met this.
set_clock() {
	local d
	d=$(curl -fsSI --max-time 30 http://download.opensuse.org/ | sed -n 's/^[Dd]ate: *//p' |
		tr -d '\r' | head -n 1) || true
	say "the clock read $(date -u '+%F %T') UTC"
	if [ -n "$d" ] && date -u -s "$d" >/dev/null; then
		say "set the clock from download.opensuse.org: $(date -u '+%F %T') UTC"
	else
		say "could not read the time over plain HTTP; the downloads may refuse their certificates"
	fi
}

# Combustion's copy of the stick's combustion/ directory, which the script runs from.
stick=$PWD

mount_subvolumes() {
	local d
	for d in /home /usr/local; do
		findmnt -n "$d" >/dev/null || mount "$d"
	done
}

# The one-card route (make-stick --card, leap/README.md § One card): Combustion read this
# config from a partition on the boot disk itself, after root. kiwi's first-boot growth of
# root stops at that partition, so make-stick grew root's partition entry instead, and
# root's filesystem may still be the image's size, with little room for the packages. It is
# grown here to fill its partition, before they install, through /home, which
# mount_subvolumes has mounted writable from the same filesystem: btrfs grows the whole
# filesystem through any writable mount of it. The route is told by the disk: a partition
# labelled combustion on root's own disk. A stick is another disk, and root is left as kiwi
# made it. Growing a filesystem that fills its partition already does nothing, so a second
# run is safe. The partition itself is deleted by hand after the first boot's checks, never
# here.
grow_root() {
	local rootdev rootdisk d
	rootdev=$(findmnt -n -v -o SOURCE /)
	[ -b "$rootdev" ] || die "cannot tell root's device: findmnt reads '$rootdev'"
	rootdisk=$(lsblk -ndo PKNAME "$rootdev")
	[ -n "$rootdisk" ] || die "cannot tell which disk $rootdev is on"
	for d in $(blkid -o device -t LABEL=combustion || true); do
		[ "$(lsblk -ndo PKNAME "$d")" = "$rootdisk" ] || continue
		[ "$(findmnt -n -v -o SOURCE /home)" = "$rootdev" ] || die "/home is not on $rootdev, so root cannot be grown through it"
		say "the config came from $d, on root's disk $rootdisk; growing root's filesystem"
		btrfs filesystem resize max /home
		say "root's filesystem is $(findmnt -n -o SIZE /home) now"
		return 0
	done
	say "root is on $rootdev; the config came from another disk, so root is left as kiwi made it"
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
	{ [ -n "$path" ] && [ -n "$name" ] && [ -n "$mode" ]; } || die "$file has no full infra- header"
	if [ "$path" = /boot/efi ]; then
		install_boot_file "$file" "$name"
		return 0
	fi
	install -D -m "$mode" "$file" "$path/$name"
	# sudo refuses to run at all over one bad file in sudoers.d, which would leave only the
	# console to elevate on.
	if [ "$path" = /etc/sudoers.d ]; then
		visudo -cf "$path/$name" >/dev/null || die "$file is not valid sudoers"
	fi
}

# A file for the Pi's FAT boot partition, which the image's fstab mounts at /boot/efi and
# this shell may not have mounted, so it is mounted first, as mount_subvolumes does /home.
# FAT keeps no modes and refuses a chmod to any but the one its mount gives, so the file is
# written, not installed with its header's mode, as bin/install-system-file does on vfat.
# A box with no FAT partition there is told so and goes on, since a firmware setting is not
# worth an unconfigured box; the first-boot log says so, three's fan then stays at full
# speed, and its unit logs why. The simulation's x86 VM has a FAT /boot/efi, and its first
# boot writes the file there.
install_boot_file() {
	local file=$1 name=$2
	findmnt -n /boot/efi >/dev/null || mount /boot/efi 2>/dev/null || true
	if [ "$(findmnt -n -o FSTYPE /boot/efi 2>/dev/null)" != vfat ]; then
		say "no FAT partition mounted at /boot/efi; $name is not installed"
		return 0
	fi
	cat "$file" > "/boot/efi/$name"
	sync "/boot/efi/$name"
	say "wrote /boot/efi/$name"
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
# forgotten file stops the first boot instead of leaving a box nobody can log in to. Any
# further arguments are carry-over paths this host requires besides, such as the optional
# items below, which make-stick carries only where the old system has them.
check_carry() {
	local host=$1 f key
	shift
	for f in shadow/root shadow/gavin gavin/authorized_keys \
		ssh/ssh_host_ed25519_key ssh/ssh_host_ed25519_key.pub "$@"; do
		[ -s "$stick/carry/$f" ] || die "carry/$f is missing or empty"
	done
	# A host with a tunnel config must carry the tunnel's credentials. A new host has
	# neither: its tunnel is made after its first boot (make-stick --new).
	if [ -e "$stick/host/system/cloudflared-config.yml" ]; then
		[ -s "$stick/carry/cloudflared/$host.json" ] || die "carry/cloudflared/$host.json is missing or empty"
	fi
	# A host whose crypttab names a key file must carry it, or its encrypted member stays
	# shut at boot and the array cannot mount. make-stick carries /etc/keys/data.key only.
	if [ -e "$stick/host/system/crypttab" ]; then
		# shellcheck disable=SC2013  # the third field alone, a path, which has no spaces in crypttab
		for key in $(awk '!/^[[:space:]]*(#|$)/ { print $3 }' "$stick/host/system/crypttab"); do
			case "$key" in
			none | -) ;;
			/etc/keys/data.key) [ -s "$stick/carry/keys/data.key" ] || die "crypttab names $key, and carry/keys/data.key is missing or empty" ;;
			*) die "crypttab names $key; only /etc/keys/data.key is carried" ;;
			esac
		done
	fi
	# The optional items, whole where they are carried at all.
	if [ -e "$stick/carry/root-ssh" ]; then
		for f in root-ssh/restore root-ssh/restore.pub; do
			[ -s "$stick/carry/$f" ] || die "carry/$f is missing or empty"
		done
	fi
	if [ -e "$stick/carry/tailscale" ]; then
		[ -s "$stick/carry/tailscale/tailscaled.state" ] || die "carry/tailscale/tailscaled.state is missing or empty"
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

# A group at the gid given, made once: a second run finds it and goes on, and a group of that
# name at another gid stops the script, since files would then belong to the wrong number.
make_group() {
	local name=$1 gid=$2 have
	have=$(getent group "$name" | cut -d: -f3 || true)
	if [ -z "$have" ]; then
		groupadd -g "$gid" "$name"
	elif [ "$have" != "$gid" ]; then
		die "a $name group exists at gid $have, not $gid"
	fi
}

# gavin keeps his Alpine uid and gid, so files he owns on the data disks stay his. A home
# left by a failed run is kept, and is his already by number.
make_gavin() {
	local uid=$1 gid=$2 have
	make_group gavin "$gid"
	have=$(id -u gavin 2>/dev/null || true)
	if [ -z "$have" ]; then
		if [ -d /home/gavin ]; then
			useradd -M -u "$uid" -g gavin -s /usr/bin/fish -c gavin gavin
		else
			useradd -m -u "$uid" -g gavin -s /usr/bin/fish -c gavin gavin
		fi
	elif [ "$have" != "$uid" ]; then
		die "a gavin user exists at uid $have, not $uid"
	fi
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

# Appends each line of a file to another that does not already hold that exact line, so a
# second run adds nothing.
append_missing() {
	local src=$1 dest=$2 line
	while IFS= read -r line || [ -n "$line" ]; do
		grep -qxF -- "$line" "$dest" 2>/dev/null || printf '%s\n' "$line" >> "$dest"
	done < "$src"
}

# The host's data entries, after the image's own root entries.
append_fstab() {
	append_missing "$stick/host/fstab.append" /etc/fstab
}

# The array's key file, at the path the host's crypttab names, which systemd-cryptsetup
# reads at boot to open the encrypted member with nobody at the console. Called before the
# fstab entries go in, so nothing that could mount the array exists without it. /etc is the
# snapshot's, so the file lives and dies with the snapshot, and the boot's relabel labels
# it. Root's alone: the directory 0700, the key 0400.
install_data_key() {
	[ -e "$stick/carry/keys/data.key" ] || return 0
	install -d -m 700 -o root -g root /etc/keys
	install -m 400 -o root -g root "$stick/carry/keys/data.key" /etc/keys/data.key
}

# Tailscale's state from the old system, so the host is the same node at the same tailnet
# address and needs no new login. /var/lib/tailscale is not among the few /var paths
# transactional-update binds into this shell (snapMount in tukit's lib/Transaction.cpp), so
# a write there would land in the snapshot's own /var, which the real /var subvolume covers
# at boot, as /home did before mount_subvolumes.
# So /var's subvolume is mounted beside, under a temporary prefix, by its own fstab entry,
# as Combustion mounts the x-initrd entries; the state is written through it and labelled
# as /var/lib/tailscale for the policy, which is not loaded yet; and the mount goes. A
# state already there is tailscaled's own, newer than the stick's, so a second run leaves
# it. Nothing in CI runs this yet: the simulation's stand-in carry-over has no Tailscale
# state. zero's simulation (plans/zero-leap.md § The build, item 6) is to prove the file is
# there after the reboot.
install_tailscale_state() {
	local f=$stick/carry/tailscale/tailscaled.state t policy
	[ -e "$f" ] || return 0
	findmnt --fstab -n /var >/dev/null || die "/var has no fstab entry, so where Tailscale's state would survive is unknown"
	t=$(mktemp -d)
	mkdir "$t/var"
	mount --target-prefix "$t" --fstab /etc/fstab /var
	if [ -e "$t/var/lib/tailscale/tailscaled.state" ]; then
		say "Tailscale's state is in /var already; the carried one is left out"
	else
		install -d -m 700 "$t/var/lib/tailscale"
		install -m 600 "$f" "$t/var/lib/tailscale/tailscaled.state"
		policy=$(sed -n 's/^SELINUXTYPE=//p' /etc/selinux/config)
		setfiles -F -r "$t" "/etc/selinux/$policy/contexts/files/file_contexts" "$t/var/lib/tailscale"
		say "installed Tailscale's state in /var/lib/tailscale"
	fi
	umount "$t/var"
	rmdir "$t/var" "$t"
}

# root's key for reading this host's backups back from three, and the known_hosts lines
# that pin three's host key (hosts/zero/system/README.md § A restore). three accepts that
# key alone, so a new one would lock restores out. /root is bound into this shell, so both
# persist, and label_subvolumes labels them.
install_restore_key() {
	local d=$stick/carry/root-ssh
	[ -e "$d/restore" ] || return 0
	install -d -m 700 /root/.ssh
	install -m 600 "$d/restore" /root/.ssh/restore
	install -m 644 "$d/restore.pub" /root/.ssh/restore.pub
	if [ -s "$d/known_hosts" ]; then
		[ -e /root/.ssh/known_hosts ] || install -m 600 /dev/null /root/.ssh/known_hosts
		append_missing "$d/known_hosts" /root/.ssh/known_hosts
	fi
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
	# A checkout already there is left as it is: a failed run's, or the finished box's, which
	# may hold work. One with no commit is a clone that never finished, and is refused.
	if [ -e /home/gavin/infra ]; then
		git -c safe.directory=/home/gavin/infra -C /home/gavin/infra rev-parse -q --verify HEAD >/dev/null ||
			die "/home/gavin/infra exists and holds no commit; move it aside"
		say "/home/gavin/infra is a checkout already; it is left as it is"
	else
		git clone --quiet https://github.com/gsfernandes81/infra.git /home/gavin/infra
	fi
	for f in "$stick"/carry/env/*.env; do
		[ -e "$f" ] || continue
		name=$(basename "$f" .env)
		[ -d "/home/gavin/infra/deployments/$name" ] || die "carry/env/$name.env has no deployment"
		install -m 600 "$f" "/home/gavin/infra/deployments/$name/.env"
	done
	chown -R gavin:gavin /home/gavin/infra
	# Each deployment's secrets directory, as its play left it in gavin's home. Combustion's
	# copy of the stick keeps no owners, so they are set here: everything gavin's, then each
	# file a deployment's .env names as TUNNEL_CREDENTIALS 65532's at 0600, as
	# server-create-deployment-tunnel.yml leaves it for the cloudflared image's user. Keyed on
	# the .env, not the file name: the dev hub's tunnel.json stays gavin's, since its
	# connector runs as gavin. Found at one's move, where the sidecars could not read their
	# credentials.
	for f in "$stick"/carry/home/.*-secrets; do
		[ -d "$f" ] || continue
		cp -a "$f" /home/gavin/
		chown -R gavin:gavin "/home/gavin/$(basename "$f")"
	done
	for f in /home/gavin/infra/deployments/*/.env; do
		[ -e "$f" ] || continue
		name=$(sed -nE 's/^[[:space:]]*(export[[:space:]]+)?TUNNEL_CREDENTIALS[[:space:]]*=[[:space:]]*["\x27]?([^"\x27]*)["\x27]?[[:space:]]*$/\2/p' "$f" | tail -n 1)
		case "$name" in
		/home/gavin/.*-secrets/*)
			[ -f "$name" ] || die "$f names $name as TUNNEL_CREDENTIALS, which the stick did not carry"
			chown 65532:65532 "$name"
			chmod 600 "$name"
			;;
		esac
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
