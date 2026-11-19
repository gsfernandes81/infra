#!/bin/bash
# shellcheck disable=SC2016,SC2013  # the checks are shell code for sh -c, quoted on purpose; pids are words
# Runs on the simulated three as root between the steps of the backup stage in host/three.sh,
# which sends from the runner as zero would, and prints PASS or FAIL per check. The first
# argument names the stage; the rest are what the runner knows: names, snapshots, UUIDs.
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
rb=/media/mirror/received-backups

# "<read-only> <received UUID>" of a subvolume, as mirror-receive reads it.
state_of() {
	echo "$(btrfs property get -ts "$1" ro | sed 's/^ro=//') $(btrfs subvolume show "$1" |
		awk '$1 == "Received" && $2 == "UUID:" { print $3 }')"
}
# What is in one name's directory, one line per subvolume with its state.
listing() {
	local s
	for s in "$rb/$1"/*; do
		[ -e "$s" ] && echo "    ${s##*/}: $(state_of "$s")"
	done
	return 0
}
owner_mode() {
	local s
	s=$(stat -c '%U %a' "$@" | sort -u)
	echo "$* : $s"
	[ "$s" = "root 700" ]
}
arrived() {
	local name=$1 snap=$2 uuid=$3 st
	listing "$name"
	st=$(state_of "$rb/$name/$snap") || return 1
	echo "$snap: $st"
	[ "$st" = "true $uuid" ]
}
count_is() {
	local n
	n=$(find "$rb/$1" -mindepth 1 -maxdepth 1 | wc -l)
	listing "$1"
	echo "$n in $1, expected $2"
	[ "$n" = "$2" ]
}
# A writable subvolume, or one with no received UUID: what an interrupted receive leaves.
halves() {
	local s st
	for s in "$rb/$1"/*; do
		[ -e "$s" ] || continue
		st=$(state_of "$s")
		case "$st" in "true -" | false\ *) echo "${s##*/}" ;; esac
	done
	return 0
}

case "${1:?stage}" in
layout)
	check "received-backups is root's, mode 700, and empty before the first send" sh -c "
		stat -c '%U %a %n' $rb; [ \"\$(stat -c '%U %a' $rb)\" = 'root 700' ] && [ -z \"\$(ls -A $rb)\" ]"
	;;
received) # <name> <snapshot> <runner's UUID>
	check "$3 arrived read-only, received from the runner's $4" arrived "$2" "$3" "$4"
	check "received-backups and its $2 directory are root's, mode 700" owner_mode "$rb" "$rb/$2"
	;;
nested) # <immich snapshot> <syncthing snapshot>
	# A nested subvolume is left out of its parent's snapshot. What the stream makes of the
	# empty placeholder the snapshot holds is reported; that nothing of it arrived is checked.
	for p in "immich/$2/data/thumbs" "immich/$2/data/encoded-video" "syncthing/$3/config"; do
		if [ ! -e "$rb/$p" ]; then
			echo "NOTE ${p#*/*/} is absent on three"
		elif [ -d "$rb/$p" ] && [ -z "$(ls -A "$rb/$p")" ]; then
			echo "NOTE ${p#*/*/} is an empty directory on three"
		fi
	done
	check "none of thumbs, encoded-video or config's contents arrived" sh -c "
		! find $rb/immich/$2/data/thumbs $rb/immich/$2/data/encoded-video $rb/syncthing/$3/config -mindepth 1 2>/dev/null | grep ."
	check "a.jpg kept its owner and mode, 1000:1000 640" sh -c "
		s=\$(stat -c '%u:%g %a' $rb/immich/$2/data/library/a.jpg); echo \"\$s\"; [ \"\$s\" = '1000:1000 640' ]"
	;;
incremental) # <immich snapshot> <syncthing snapshot>
	check "a file added on the runner arrived, and one deleted there is gone" sh -c "
		ls $rb/immich/$2/data/library $rb/syncthing/$3/share
		[ -e $rb/immich/$2/data/library/added.jpg ] && [ ! -e $rb/immich/$2/data/library/b.jpg ] &&
		[ -e $rb/syncthing/$3/share/added.txt ] && [ ! -e $rb/syncthing/$3/share/gone.txt ]"
	;;
confined) # <immich count> <syncthing count>
	check "nothing arrived for the refused calls: still $2 and $3 snapshots, and no other directory" sh -c "
		ls -A $rb; [ \"\$(ls -A $rb | tr '\n' ' ')\" = 'immich syncthing ' ] &&
		[ \$(ls -A $rb/immich | wc -l) = $2 ] && [ \$(ls -A $rb/syncthing | wc -l) = $3 ]"
	check "nothing ran from the commands the key asked for" sh -c '
		ls /tmp/sim-escape* 2>/dev/null; ! ls /tmp/sim-escape* >/dev/null 2>&1'
	# The forced command refuses a name before sudo; these show sudoers and the script refuse
	# it too, each on its own.
	check "sudo lets the backup user run mirror-receive immich, unasked for a password" \
		runuser -u backup -- sudo -n -l /usr/local/sbin/mirror-receive immich
	check "sudo refuses the backup user mirror-receive with another name" sh -c '
		! runuser -u backup -- sudo -n -l /usr/local/sbin/mirror-receive other'
	check "sudo refuses the backup user anything else" sh -c '
		! runuser -u backup -- sudo -n -l /usr/bin/true && ! runuser -u backup -- sudo -n true'
	check "mirror-receive itself refuses a name off its list" sh -c '
		out=$(/usr/local/sbin/mirror-receive other < /dev/null 2>&1); echo "$out"; echo "$out" | grep -q refused'
	check "sudoers-backup passes visudo" visudo -cf /etc/sudoers.d/60-backup
	;;
locked)
	# If the LUKS volume stays open, say what still holds it: a unit's state, the device's
	# open count, and any process whose mount namespace still has the array.
	if test -e /dev/mapper/mirror; then
		echo "the LUKS volume is still open after the lock:"
		systemctl show -p ActiveState -p Result media-mirror.mount systemd-cryptsetup@mirror.service | sed 's/^/    /'
		journalctl -b --no-pager -u systemd-cryptsetup@mirror.service -u media-mirror.mount | tail -n 12 | sed 's/^/    /'
		dmsetup info mirror 2>&1 | grep -iE 'open|state' | sed 's/^/    /'
		for p in $(grep -l mapper/mirror /proc/[0-9]*/mountinfo 2>/dev/null | cut -d/ -f3 | sort -un); do
			echo "    pid $p: $(tr '\0' ' ' < "/proc/$p/cmdline" | cut -c1-100) [$(readlink "/proc/$p/ns/mnt")]"
		done | head -n 20
		echo "    the root mount namespace: $(readlink /proc/1/ns/mnt)"
	fi
	check "the array is locked, its LUKS volume closed, and received-backups not there" sh -c "
		! findmnt /media/mirror && ! test -e /dev/mapper/mirror && ! test -e $rb"
	;;
has-half) # <name>: exits 0 while a receive is under way or was left half done
	listing "$2"
	[ -n "$(halves "$2")" ]
	;;
plant) # <name>
	# What a receive killed outright leaves, by a power cut or the OOM killer, before its
	# own clean-up could run: a writable subvolume, and one made read-only with no received
	# UUID.
	btrfs subvolume create "$rb/$2/$2-2001-01-01T0000Z" > /dev/null
	btrfs subvolume create "$rb/$2/$2-2001-01-02T0000Z" > /dev/null
	btrfs property set -ts "$rb/$2/$2-2001-01-02T0000Z" ro true
	planted() { listing "$1"; [ "$(halves "$1" | wc -l)" -ge 2 ]; }
	check "two half-received stand-ins are in place for the next receive to find" planted "$2"
	;;
clean) # <name> <snapshot>
	cleaned() { listing "$1"; [ -z "$(halves "$1")" ] && [ "$(state_of "$rb/$1/$2" | cut -d' ' -f1)" = true ]; }
	check "the next receive deleted every half-received subvolume, and $3 arrived" cleaned "$2" "$3"
	;;
n) # <name>: prints how many snapshots three holds for it
	find "$rb/$2" -mindepth 1 -maxdepth 1 | wc -l
	;;
count) # <name> <n>
	check "three holds $3 $2 snapshots" count_is "$2" "$3"
	;;
pruned) # <name> <snapshot> <other name> <its count>
	check "with 0 days kept, only the newest $2 snapshot, $3, survives" sh -c "
		ls -1 $rb/$2; [ \"\$(ls -1 $rb/$2)\" = '$3' ]"
	check "$4's snapshots were left alone: still $5" count_is "$4" "$5"
	;;
restore) # <immich snapshot> <Postgres image>
	src=$rb/immich/$2
	r=/media/mirror/restore
	before=$(state_of "$src")
	rm -rf "$r" && mkdir -p "$r"
	docker rm -f sim-restore > /dev/null 2>&1
	check "a reflink copy of the received db" cp -a --reflink=always "$src/db" "$r/db"
	check "Postgres starts on the copy, recovering as from a power cut" sh -c "
		docker run -d --name sim-restore --network none -v $r/db:/var/lib/postgresql/data $3 > /dev/null || exit 1
		for i in \$(seq 1 90); do docker logs sim-restore 2>&1 | grep -q 'ready to accept connections' && break; sleep 2; done
		docker logs sim-restore 2>&1 | grep -E 'interrupted|recovery|redo|ready' | head -n 8
		docker logs sim-restore 2>&1 | grep -q 'automatic recovery in progress' &&
		docker logs sim-restore 2>&1 | grep -q 'ready to accept connections'"
	check "it answers with every one of the 100 rows written before the snapshot" sh -c "
		out=\$(docker exec sim-restore psql -U postgres -tAc 'select count(*) filter (where id <= 100), count(*) from t')
		echo \"rows up to 100, and in all: \$out\"; [ \"\${out%%|*}\" = 100 ]"
	docker rm -f sim-restore > /dev/null 2>&1
	rm -rf "$r"
	untouched() { local after; after=$(state_of "$src"); echo "before: $before; after: $after"; [ "$after" = "$before" ] && [ "${after%% *}" = true ]; }
	check "the received snapshot is untouched: read-only, with its received UUID" untouched
	;;
esac
