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
# WHAT THIS DOES, AND WHAT IT LEAVES. The first boot does only what needs no network and
# cannot be done later: the image's package baseline, the carry-over, the login (gavin, his
# keys, sshd and its drop-in, the sudoers file), the host's old ssh keys, the volume tars,
# and the secrets staged in /root/carry. Combustion brings up no network, so nothing here
# downloads, installs a package or reads the clock. The rest is the play's, over ssh once
# the box is up: packages and locks, the pinned binaries, every other tracked file, the
# fstab entries, the units, the checkout and the network profile (plans/pi-setup.md,
# ansible/playbooks/server-setup-leap.yml).
#
# Nothing here is generated: each file it installs is a reviewed file from the repo,
# installed at the path its own infra- header names, or a carry-over file copied verbatim.

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
	# A host with a tunnel config must carry the tunnel's credentials. A new host (carry/NEW,
	# which make-stick --new writes) has none: its tunnel is made after its first boot.
	if [ ! -e "$stick/carry/NEW" ] && [ -e "$stick/host/system/cloudflared-config.yml" ]; then
		[ -s "$stick/carry/cloudflared/$host.json" ] || die "carry/cloudflared/$host.json is missing or empty"
	fi
	# A host whose crypttab names a key file must carry it, or its encrypted member stays
	# shut at boot and the array cannot mount. make-stick carries /etc/keys/data.key only. A
	# new host has none: the owner adds one to the array before the play installs crypttab.
	if [ ! -e "$stick/carry/NEW" ] && [ -e "$stick/host/system/crypttab" ]; then
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

# The array's key file, at the path the host's crypttab names, which systemd-cryptsetup
# reads at boot to open the encrypted member with nobody at the console. Called before the
# fstab entries go in (the play's), so nothing that could mount the array exists without it. /etc is the
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

# Named volumes cannot be restored here, with no Docker running, so their tar files wait in
# root's home for the runbook's restore, and leave the stick that is about to be erased.
keep_volume_tars() {
	local f
	for f in "$stick"/carry/volumes/*.tar; do
		[ -e "$f" ] || continue
		install -D -m 600 "$f" "/root/volumes/$(basename "$f")"
	done
}

# The image's package baseline, written before anything can install a package: one name per
# line, sorted. The play reads it to tell the image's packages from the ones it added, so a
# package it later drops from its list is only removed when it is not in the image. Written
# once: a second run, over a snapshot a first run finished, would record a changed system,
# so an existing file is left alone.
record_baseline() {
	[ -e /etc/infra/image-packages ] && return 0
	install -d -m 755 /etc/infra
	rpm -qa --qf '%{NAME}\n' | sort -u > /etc/infra/image-packages
	chmod 644 /etc/infra/image-packages
}

# The way in for the play's first run: sshd's drop-in and gavin's sudoers file, both
# tracked, so the play logs in as gavin and uses sudo with gavin's own password. The unit
# is enabled here and starts at the boot, since the play has nothing else to reach it by.
install_login() {
	install_tracked "$stick/host/system/sshd-infra.conf"
	install_tracked "$stick/host/system/sudoers-gavin"
	systemctl enable sshd.service
}

# Each deployment's .env and secrets directory, staged for the play. /root is bound into
# this shell by transactional-update (see the header), so these persist as keep_volume_tars'
# files do. The play puts them in the checkout once it has cloned it, then removes
# /root/carry; the ownership rules for them (gavin's, and TUNNEL_CREDENTIALS' file 65532's
# at 0600) are the play's too. Copies of the stick's own files, so a second run overwrites
# its own and adds nothing.
stage_carry() {
	local f
	install -d -m 700 -o root -g root /root/carry /root/carry/env /root/carry/home
	for f in "$stick"/carry/env/*.env; do
		[ -e "$f" ] || continue
		install -m 600 -o root -g root "$f" "/root/carry/env/$(basename "$f")"
	done
	for f in "$stick"/carry/home/.*-secrets; do
		[ -d "$f" ] || continue
		rm -rf "/root/carry/home/$(basename "$f")"
		cp -a "$f" /root/carry/home/
		chown -R root:root "/root/carry/home/$(basename "$f")"
		find "/root/carry/home/$(basename "$f")" -type d -exec chmod 700 {} +
		find "/root/carry/home/$(basename "$f")" -type f -exec chmod 600 {} +
	done
}
