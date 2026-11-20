#!/bin/bash
# shellcheck disable=SC2016  # the checks are shell code for sh -c, quoted on purpose
# Runs on the simulated three as root between the steps of the rename in host/three.sh's
# migrate variant (SIM_VARIANT=migrate), and prints PASS or FAIL per check. The rename's
# own steps are the fish blocks of hosts/three/leap/README.md § The rename, run as written;
# this script only sets the box up as it was before them and reads what each one left.
# The first argument names the step.
set -u

check() {
	local name=$1 out
	shift
	if out=$("$@" 2>&1); then
		echo "PASS $name"
	else
		echo "FAIL $name"
		printf '%s\n' "$out" | tail -n 15 | sed 's/^/    /'
	fi
}
old=/root/sim-old
rec=/root/sim-rename-record
# What the rename must leave untouched in three's Syncthing: its subvolume's UUID, and every
# path, size and content under it, Syncthing's identity among them.
syncthing_uuid() { btrfs subvolume show "$1" | awk '$1 == "UUID:" { print $2 }'; }
syncthing_tree() { (cd "$1" && find . -printf '%p %s\n' | sort && find . -type f -print0 | sort -z | xargs -0 sha256sum) | sha256sum | cut -d' ' -f1; }
header() { sed -n "s/^# infra-$2:[[:space:]]*//p" "$1"; }

case "${1:?step}" in
regress)
	# three as its first boot made it on 2026-11-18: the tree before the pull's files, which
	# host/three.sh fetched into the tarball. The old-only files go in at the paths their
	# headers name, crypttab and the fan's script go back to their old text, the new-only
	# files come out, the users are as the old first boot made them, fstab holds the old
	# line, and a snapshot swaps /media/backup for /media/mirror, for the reboot after.
	rm -rf "$old" && mkdir -p "$old" && tar -C "$old" -xf /tmp/sim-old.tar || { echo "FAIL no old tree"; exit 0; }
	for f in "$old"/install/*; do
		p=$(header "$f" path); n=$(header "$f" name); m=$(header "$f" mode)
		install -D -m "$m" "$f" "$p/$n" && echo "    installed the old $p/$n"
	done
	while read -r p; do
		[ -n "$p" ] && rm -f "$p" && echo "    removed the new $p"
	done < "$old/remove"
	rmdir /etc/systemd/system/media-backup.mount.d 2> /dev/null
	userdel restore && rm -rf /home/restore
	usermod -s /bin/bash backup
	grep -v '[[:space:]]/media/backup[[:space:]]' /etc/fstab > /etc/fstab.sim && cat "$old/fstab.append" >> /etc/fstab.sim &&
		mv /etc/fstab.sim /etc/fstab && restorecon /etc/fstab
	systemctl daemon-reload
	systemctl restart argon-fan.service
	transactional-update --non-interactive run sh -c 'mkdir /media/mirror && rmdir /media/backup' > /root/sim-tu.log 2>&1 ||
		{ echo "FAIL the snapshot that swaps the mountpoints failed:"; tail -n 20 /root/sim-tu.log | sed 's/^/    /'; }
	check "the box is three as of 2026-11-18: old crypttab, fstab line without nosuid, the push's units, no restore user" sh -c '
		grep -qE "^mirror[[:space:]]+LABEL=mirror-luks" /etc/crypttab &&
		grep "[[:space:]]/media/mirror[[:space:]]" /etc/fstab | grep -v nosuid | grep -q noauto &&
		test -e /etc/systemd/system/mirror-snapshot.timer && test -e /etc/systemd/system/docker.service.d/infra-mirror.conf &&
		test -e /home/backup/.ssh/authorized_keys && ! test -e /etc/systemd/system/media-backup.mount.d &&
		! id restore && getent passwd backup | grep -q ":/bin/bash$" && grep -q "by-label/mirror-luks" /usr/local/sbin/argon-fan'
	;;
old)
	# After the old make-mirror and the old unlock: the push's layout, and what its timer made.
	check "the old array is mounted at /media/mirror, labelled mirror, holding incoming, snapshots and syncthing" sh -c '
		findmnt -no SOURCE /media/mirror; ls /media/mirror
		[ "$(findmnt -no SOURCE /media/mirror)" = /dev/mapper/mirror ] && [ "$(btrfs filesystem label /media/mirror)" = mirror ] &&
		[ "$(ls /media/mirror | tr "\n" " ")" = "incoming snapshots syncthing " ] && ! test -e /media/backup'
	systemctl start mirror-snapshot.service
	btrfs subvolume snapshot -r /media/mirror/incoming /media/mirror/snapshots/2026-11-19 > /dev/null
	check "the old timer's service and a hand snapshot leave two read-only snapshots of the empty incoming" sh -c '
		ls /media/mirror/snapshots; [ "$(ls /media/mirror/snapshots | wc -l)" = 2 ] &&
		for s in /media/mirror/snapshots/*; do [ "$(btrfs property get -ts "$s" ro)" = ro=true ] || exit 1; done'
	;;
syncthing-up) # after the old deployment of syncthing-three started on /media/mirror/syncthing
	s=/media/mirror/syncthing
	for i in $(seq 1 60); do [ -s $s/config/cert.pem ] && break; sleep 3; done
	install -d -o 1000 -g 1000 $s/sim-folder
	for i in 1 2 3 4 5; do head -c 100k /dev/urandom > $s/sim-folder/file-$i; done
	chown -R 1000:1000 $s/sim-folder
	check "Syncthing made its identity on the old array, and holds data" sh -c "
		ls -l $s/config/cert.pem $s/sim-folder | head -n 4; test -s $s/config/cert.pem"
	;;
record) # once Syncthing is stopped, by the README's rename 2
	syncthing_uuid /media/mirror/syncthing > $rec && syncthing_tree /media/mirror/syncthing >> $rec
	check "Syncthing is stopped, and its subvolume recorded" sh -c "
		cat $rec; [ \"\$(wc -l < $rec)\" = 2 ] && ! docker ps --format '{{.Names}}' | grep -qx syncthing"
	;;
stray-in) touch /media/mirror/incoming/sim-stray ;;
stray-out) rm /media/mirror/incoming/sim-stray ;;
refused) # rename 3 run with a stray file in incoming
	check "rename 3 refused, and deleted nothing: incoming, both snapshots and no immich" sh -c '
		ls /media/mirror /media/mirror/snapshots
		test -e /media/mirror/incoming/sim-stray && [ "$(ls /media/mirror/snapshots | wc -l)" = 2 ] && ! test -e /media/mirror/immich'
	;;
reshaped)
	m=/media/mirror
	check "rename 3 left immich root's 755, current a subvolume backup's 700, .snapshots root's 754, state backup's 700" sh -c "
		stat -c '%i %U %a %n' $m/immich $m/immich/current $m/immich/current/.snapshots $m/immich/state
		[ \"\$(stat -c '%U %a' $m/immich)\" = 'root 755' ] && [ \"\$(stat -c '%i %U %a' $m/immich/current)\" = '256 backup 700' ] &&
		[ \"\$(stat -c '%i %U %a' $m/immich/current/.snapshots)\" = '256 root 754' ] && [ \"\$(stat -c '%U %a' $m/immich/state)\" = 'backup 700' ]"
	check "and the top of the array holds immich and syncthing alone, and three subvolumes" sh -c "
		btrfs subvolume list $m; [ \"\$(ls -A $m | tr '\n' ' ')\" = 'immich syncthing ' ] &&
		[ \"\$(btrfs subvolume list $m | awk '{ print \$NF }' | sort | tr '\n' ' ')\" = 'immich/current immich/current/.snapshots syncthing ' ]"
	check "Syncthing's subvolume is the one recorded, unchanged" bash -c "
		$(declare -f syncthing_uuid syncthing_tree)
		[ \"\$(syncthing_uuid $m/syncthing)\" = \"\$(sed -n 1p $rec)\" ] && [ \"\$(syncthing_tree $m/syncthing)\" = \"\$(sed -n 2p $rec)\" ]"
	;;
btrfs-label)
	check "rename 4: the btrfs is labelled backup" sh -c '[ "$(btrfs filesystem label /media/mirror)" = backup ]'
	;;
locked)
	check "rename 5: the array is unmounted and its LUKS volume closed" sh -c '
		! findmnt /media/mirror && ! test -e /dev/mapper/mirror && ! systemctl is-active --quiet docker'
	;;
luks-label)
	check "rename 6: the drive answers to backup-luks alone, and its header backup is root's, 600" sh -c '
		d=$(blkid -L backup-luks); echo "$d"; cryptsetup luksDump "$d" | grep -E "^Label:"
		[ -b "$d" ] && [ -z "$(blkid -L mirror-luks)" ] && cryptsetup luksDump "$d" | grep -qE "^Label:[[:space:]]+backup-luks$" &&
		[ "$(readlink -f /dev/disk/by-label/backup-luks)" = "$d" ] &&
		[ "$(stat -c "%U %a" /root/backup-luks-header.img)" = "root 600" ] &&
		cryptsetup isLuks --header /root/backup-luks-header.img "$d"'
	;;
fstab)
	check "rename 7: one /media/backup line, fstab.append's, no /media/mirror line, the old fstab copied at 600" sh -c '
		grep /media/ /etc/fstab
		[ "$(grep -c "[[:space:]]/media/backup[[:space:]]" /etc/fstab)" = 1 ] && grep -qxF -f /home/gavin/infra/hosts/three/leap/fstab.append /etc/fstab &&
		! grep -q "[[:space:]]/media/mirror[[:space:]]" /etc/fstab && [ "$(stat -c "%U %a" /root/fstab.before-rename)" = "root 600" ] &&
		[ -z "$(restorecon -nv /etc/fstab)" ]'
	;;
units)
	check "rename 8 and 9: crypttab names backup, the new units are in, the old ones gone and copied with their modes" sh -c '
		grep -E "^[^#]" /etc/crypttab; grep -qxE "backup[[:space:]]+LABEL=backup-luks[[:space:]]+none[[:space:]]+luks,noauto,password-cache=no" /etc/crypttab &&
		test -e /etc/systemd/system/media-backup.mount.d/infra-wants.conf && test -e /etc/systemd/system/docker.service.d/infra-backup.conf &&
		test -e /etc/systemd/system/backup-scrub.service && test -e /etc/systemd/system/backup-scrub.timer &&
		! ls /etc/systemd/system/docker.service.d/infra-mirror.conf /etc/systemd/system/media-mirror.mount.d /etc/systemd/system/mirror-* \
			/usr/local/sbin/mirror-snapshot /etc/rsync-backup.conf /home/backup/.ssh/authorized_keys 2> /dev/null &&
		[ "$(stat -c %a /root/rename-2026-11-20/usr/local/sbin/mirror-snapshot)" = 755 ] &&
		[ "$(stat -c %a /root/rename-2026-11-20/etc/systemd/system/mirror-scrub.timer)" = 644 ] &&
		! ls /etc/systemd/system/timers.target.wants/mirror-* 2> /dev/null'
	check "systemd has the new mount and its wants, and Docker the new condition" sh -c '
		systemctl show -p What -p Where media-backup.mount; systemctl show -p Wants --value media-backup.mount
		[ "$(systemctl show -p What --value media-backup.mount)" = /dev/mapper/backup ] &&
		systemctl show -p Wants --value media-backup.mount | grep -qw backup-scrub.timer &&
		systemctl cat docker.service | grep -q "^ConditionPathIsMountPoint=/media/backup$" && ! systemctl cat docker.service | grep -q /media/mirror'
	check "backup has no shell, restore has one for its forced command, both homes root's" sh -c '
		getent passwd backup restore
		getent passwd backup | grep -q ":/usr/sbin/nologin$" && getent passwd restore | grep -q ":/home/restore:/bin/bash$" &&
		[ "$(stat -c "%U %a" /home/restore/.ssh)" = "root 755" ]'
	;;
fan)
	check "rename 10: the fan's unit finds the drive by backup-luks" sh -c '
		d=$(basename "$(readlink -f /dev/disk/by-label/backup-luks)")
		for i in $(seq 1 12); do journalctl -b --no-pager -u argon-fan --since -3min | grep -q "drive found at /dev/$d," && break; sleep 5; done
		journalctl -b --no-pager -u argon-fan | tail -n 3
		grep -q "by-label/backup-luks" /usr/local/sbin/argon-fan &&
		journalctl -b --no-pager -u argon-fan --since -3min | grep -q "drive found at /dev/$d," && systemctl is-active argon-fan.service'
	;;
snapshot)
	check "rename 11: the default snapshot is new, with /media/backup and no /media/mirror, the running one unchanged" sh -c '
		b=$(findmnt -no SOURCE / | sed -n "s|.*\[/@\(.*\)\]$|\1|p"); d=$(btrfs subvolume get-default / | sed -n "s|.* path @||p")
		echo "booted $b, default $d"; ls "$d/media"
		[ -n "$b" ] && [ -n "$d" ] && [ "$b" != "$d" ] && test -d "$d/media/backup" && ! test -e "$d/media/mirror" &&
		test -d /media/mirror && ! test -e /media/backup'
	;;
booted)
	check "rename 13: the boot is the new default snapshot, /media/backup and no /media/mirror, the array locked" sh -c '
		b=$(findmnt -no SOURCE / | sed -n "s|.*\[/@\(.*\)\]$|\1|p"); d=$(btrfs subvolume get-default / | sed -n "s|.* path @||p")
		echo "booted $b, default $d"; ls -d /media/*
		[ -n "$b" ] && [ "$b" = "$d" ] && [ "$(ls -d /media/* | tr "\n" " ")" = "/media/backup " ] &&
		! systemctl is-active --quiet systemd-cryptsetup@backup.service && ! findmnt /media/backup'
	show_relabel=$(journalctl -b -1 --no-pager 2> /dev/null | grep -ciE 'relabel' || true)
	echo "    the boot before this one logged $show_relabel lines naming a relabel"
	;;
unlocked)
	m=/media/backup
	check "rename 14: the array opens as backup and mounts at /media/backup with nosuid, nodev and the container context" sh -c "
		findmnt -no SOURCE,OPTIONS $m; o=\$(findmnt -no SOURCE,OPTIONS $m)
		echo \"\$o\" | grep -q '^/dev/mapper/backup ' && echo \"\$o\" | grep -qw nosuid && echo \"\$o\" | grep -qw nodev &&
		echo \"\$o\" | grep -q 'context=.*container_file_t' && [ \"\$(btrfs filesystem label $m)\" = backup ]"
	check "Syncthing's subvolume is the one recorded before the rename: the same UUID, every path, size and content" bash -c "
		$(declare -f syncthing_uuid syncthing_tree)
		echo \"uuid \$(syncthing_uuid $m/syncthing), recorded \$(sed -n 1p $rec)\"
		[ \"\$(syncthing_uuid $m/syncthing)\" = \"\$(sed -n 1p $rec)\" ] && [ \"\$(syncthing_tree $m/syncthing)\" = \"\$(sed -n 2p $rec)\" ]"
	check "Docker started with the mount, and Syncthing stayed stopped" sh -c "
		for i in \$(seq 1 30); do systemctl is-active --quiet docker && break; sleep 2; done
		systemctl is-active docker && ! docker ps --format '{{.Names}}' | grep -qx syncthing"
	;;
redeployed)
	check "Syncthing runs on /media/backup/syncthing, healthy, with the identity it had" sh -c "
		for i in \$(seq 1 60); do [ \"\$(docker inspect syncthing --format '{{.State.Health.Status}}')\" = healthy ] && break; sleep 5; done
		docker inspect syncthing --format '{{range .Mounts}}{{.Source}} {{end}}{{.State.Health.Status}}'
		[ \"\$(docker inspect syncthing --format '{{range .Mounts}}{{.Source}} {{end}}{{.State.Health.Status}}')\" = '/media/backup/syncthing healthy' ] &&
		test -s /media/backup/syncthing/config/cert.pem"
	;;
cleaned)
	check "rename 18: the header backup and the copies are gone" sh -c '
		! ls /root/backup-luks-header.img /root/rename-2026-11-20 /root/fstab.before-rename /home/gavin/rename-syncthing.txt 2> /dev/null'
	;;
esac
