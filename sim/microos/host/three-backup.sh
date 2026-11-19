#!/bin/bash
# shellcheck disable=SC2016  # the checks are shell code for sh -c, quoted on purpose
# Runs on the simulated three as root between the steps of the backup stage in host/three.sh,
# where the runner stands in for zero and three pulls from it, and prints PASS or FAIL per
# check. The first argument names the step; the rest are what the runner knows.
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
d=$rb/immich
cur=$d/current
cfg=received-immich

# Three's snapshots, as "<number> <description>", oldest first, read from snapper's own
# info.xml files rather than its table, whose columns differ between versions.
snaps() {
	local f n
	for f in "$cur"/.snapshots/*/info.xml; do
		[ -e "$f" ] || continue
		n=${f%/info.xml}
		n=${n##*/}
		echo "$n $(sed -n 's:.*<description>\(.*\)</description>.*:\1:p' "$f")"
	done | sort -n
	return 0
}
count() { snaps | grep -c . || true; }
newest() { snaps | tail -n 1 | cut -d' ' -f1; }
unit_result() { systemctl show -p Result --value "$1"; }
# mirror-snapshot.service is started by the pull's OnSuccess= as the pull ends, so it is
# waited for before anything is read.
settle() {
	local i
	sleep 2
	for i in $(seq 1 60); do
		! systemctl list-jobs --no-legend 2>/dev/null | grep -qE 'mirror-(pull|snapshot)' &&
			! systemctl is-active --quiet mirror-pull.service mirror-snapshot.service && return 0
		sleep 2
	done
	return 1
}
rate() {
	local dir=/run/systemd/system/mirror-pull.service.d
	rm -f "$dir"/sim-rate.conf
	if [ "$1" != default ]; then
		mkdir -p "$dir"
		printf '[Service]\nEnvironment=MIRROR_PULL_BWLIMIT=%s\n' "$1" > "$dir/sim-rate.conf"
	fi
	systemctl daemon-reload
}
journal() {
	journalctl --no-pager -o cat --since "@$1" -u mirror-pull.service -u mirror-snapshot.service |
		grep -vE '^(Starting|Finished|Started|Stopped|Deactivated) ' | tail -n "${2:-12}" | sed 's/^/    | /'
}

case "${1:?step}" in
layout)
	check "received-backups and immich are root's, mode 755" sh -c "
		s=\$(stat -c '%U %a' $rb $d | sort -u); echo \"\$s\"; [ \"\$s\" = 'root 755' ]"
	check "current is a subvolume, the backup user's, mode 700" sh -c "
		stat -c '%i %U %a' $cur; [ \"\$(stat -c '%i %U %a' $cur)\" = '256 backup 700' ]"
	check "current/.snapshots is a subvolume, root's, mode 750, holding no snapshot yet" sh -c "
		stat -c '%i %U %a' $cur/.snapshots; [ \"\$(stat -c '%i %U %a' $cur/.snapshots)\" = '256 root 750' ] &&
		[ -z \"\$(ls -A $cur/.snapshots)\" ]"
	check "state is the backup user's, mode 700" sh -c "
		[ \"\$(stat -c '%U %a' $d/state)\" = 'backup 700' ]"
	check "snapper reads three's config with --no-dbus" snapper --no-dbus -c "$cfg" list
	;;
key)
	# As hosts/three/leap/README.md § The backup has the owner make it. The public half is
	# printed last, for the runner to put in zero's mirror line.
	ssh-keygen -q -t ed25519 -N '' -C 'three mirror-pull' -f /home/backup/.ssh/zero-pull &&
		chown backup:backup /home/backup/.ssh/zero-pull /home/backup/.ssh/zero-pull.pub &&
		stat -c '%U %a %n' /home/backup/.ssh/zero-pull >&2 &&
		cut -d' ' -f1,2 /home/backup/.ssh/zero-pull.pub
	;;
lan)
	# The README's runtime drop-in for the first pull over the LAN: no rate limit, until the
	# next boot or its removal.
	mkdir -p /run/systemd/system/mirror-pull.service.d
	printf '[Service]\nEnvironment=MIRROR_PULL_BWLIMIT=0\n' > /run/systemd/system/mirror-pull.service.d/lan.conf
	systemctl daemon-reload
	systemctl show -p Environment --value mirror-pull.service
	;;
rate) # <KiB/s | default>, a second drop-in over the README's, for the cut pulls
	rate "$2"
	;;
pull) # <expected zero snapshot> <expected count after> : a pull that must succeed
	t0=$(date +%s)
	snaps > /root/sim-snaps-before
	systemctl start mirror-pull.service
	settle || echo "FAIL the pull or its snapshot did not finish in two minutes"
	journal "$t0"
	check "the pull of zero's snapshot $2 succeeded" sh -c "
		[ \"\$(systemctl show -p Result --value mirror-pull.service)\" = success ] &&
		journalctl --no-pager -o cat --since @$t0 -u mirror-pull.service | grep -q 'pulled snapshot $2 of '"
	check "three took one snapshot after it, 'pulled $2', and holds $3" sh -c "
		$(declare -f snaps); cur=$cur; snaps
		[ \"\$(snaps | grep -c .)\" = $3 ] && [ \"\$(snaps | tail -n 1 | cut -d' ' -f2-)\" = 'pulled $2' ] &&
		[ \"\$(systemctl show -p Result --value mirror-snapshot.service)\" = success ]"
	check "last-pulled names snapshot $2, root's" sh -c "
		cat $d/last-pulled; stat -c '%U %a' $d/last-pulled
		[ \"\$(cut -d' ' -f1 $d/last-pulled)\" = $2 ] && [ \"\$(stat -c %U $d/last-pulled)\" = root ]"
	check "every snapshot three held before is still there" sh -c "
		$(declare -f snaps); cur=$cur; snaps > /root/sim-snaps-after
		! comm -23 /root/sim-snaps-before /root/sim-snaps-after | grep ."
	;;
nothing-new) # <count>
	t0=$(date +%s)
	lp=$(cat "$d/last-pulled")
	systemctl start mirror-pull.service
	settle || true
	journal "$t0" 4
	check "a pull with nothing new copies nothing and takes no snapshot" sh -c "
		$(declare -f snaps); cur=$cur
		journalctl --no-pager -o cat --since @$t0 -u mirror-pull.service | grep -q 'nothing new' &&
		[ \"\$(snaps | grep -c .)\" = $2 ] && [ \"\$(cat $d/last-pulled)\" = '$lp' ] &&
		[ ! -e $d/state/pulled ] &&
		[ \"\$(systemctl show -p ConditionResult --value mirror-snapshot.service)\" = no ]"
	;;
first) # <zero snapshot>
	check "current holds the library and the database, and no .snapshots of zero's" sh -c "
		ls $cur $cur/data $cur/.snapshots
		[ -s $cur/data/library/big.bin ] && [ -f $cur/db/PG_VERSION ] &&
		! ls $cur/.snapshots | grep -v '^[0-9]*$'"
	check "thumbs and encoded-video arrived as empty directories" sh -c "
		for p in data/thumbs data/encoded-video; do
			[ -d $cur/\$p ] && [ -z \"\$(ls -A $cur/\$p)\" ] || { ls -la $cur/\$p; exit 1; }
		done"
	check "a.jpg's real owner and mode are kept in rsync's xattr, 1000:1000 640" sh -c "
		s=\$(python3 -c 'import os,sys; print(os.getxattr(sys.argv[1], \"user.rsync.%stat\").decode())' $cur/data/library/a.jpg); echo \"\$s\"
		[ \"\$s\" = '100640 0,0 1000:1000' ] && [ \"\$(stat -c %U $cur/data/library/a.jpg)\" = backup ]"
	check "a symlink zero sent is stored munged, leading nowhere" sh -c "
		t=\$(readlink $cur/data/library/link.jpg); echo \"link.jpg -> \$t\"
		[ \"\$t\" = /rsyncd-munged/a.jpg ] && [ ! -e /rsyncd-munged ]"
	;;
changes) # <before ctime of big.bin>
	check "a file added on zero arrived, one deleted is gone from current and kept in the first snapshot" sh -c "
		ls $cur/data/library
		first=\$(ls $cur/.snapshots | sort -n | head -n 1)
		[ -e $cur/data/library/c.jpg ] && [ ! -e $cur/data/library/b.jpg ] &&
		[ -e $cur/.snapshots/\$first/snapshot/data/library/b.jpg ]"
	check "big.bin, unchanged on zero, was not written again" sh -c "
		s=\$(stat -c '%i %Z' $cur/data/library/big.bin); echo \"before: $2; now: \$s\"; [ \"\$s\" = '$2' ]"
	;;
ctime)
	stat -c '%i %Z' "$cur/data/library/big.bin"
	;;
delete-calibration)
	# What --delete would do to three's snapshots without mirror-pull's exclude and protect
	# filters: a dry run of the same transfer with them left out. As root, since the backup
	# user cannot even list .snapshots (root's, 750), which is a second guard. It must show
	# rsync deleting inside .snapshots, or the checks after the real pulls prove nothing.
	n=$(sed -n 's/ .*//p' "$d/last-pulled")
	rsync -n -i -aHAX --numeric-ids --fake-super --munge-links --delete \
		-e 'ssh -F /home/backup/.ssh/config -o UserKnownHostsFile=/home/backup/.ssh/known_hosts' \
		"mirror@zero::snapshots/$n/snapshot/" "$cur/" > /root/sim-delete.log 2>&1
	check "calibration: without the filters, --delete would empty three's .snapshots" sh -c "
		grep -m3 'deleting .*\.snapshots/' /root/sim-delete.log || tail -n 5 /root/sim-delete.log
		grep -q 'deleting .*\.snapshots/' /root/sim-delete.log"
	;;
running) # waits until a pull is under way, its first bytes of <file> in current/
	for i in $(seq 1 120); do
		if systemctl is-active --quiet mirror-pull.service && [ -s "$cur/$2" ]; then
			echo "the pull is under way: $(stat -c %s "$cur/$2") bytes of $2 so far"
			exit 0
		fi
		sleep 1
	done
	echo "the pull never got under way: $(systemctl show -p ActiveState,Result mirror-pull.service | tr '\n' ' ')"
	exit 1
	;;
failed) # <since> <exit status, or any> <count> : a pull that must have failed, leaving nothing
	settle || true
	journal "$2" 6
	check "the pull failed with exit $3" sh -c "
		systemctl show -p Result -p ExecMainStatus mirror-pull.service
		st=\$(systemctl show -p ExecMainStatus --value mirror-pull.service)
		[ \"\$(systemctl show -p Result --value mirror-pull.service)\" = exit-code ] &&
		case $3 in any) [ \"\$st\" != 0 ] ;; *) [ \"\$st\" = $3 ] ;; esac"
	check "no snapshot was taken, last-pulled is unchanged, and nothing is marked pulled" sh -c "
		$(declare -f snaps); cur=$cur; snaps
		[ \"\$(snaps | grep -c .)\" = $4 ] && [ \"\$(cat $d/last-pulled)\" = \"\$(cat /root/sim-last-pulled)\" ] &&
		[ ! -e $d/state/pulled ]"
	;;
mark)
	cp "$d/last-pulled" /root/sim-last-pulled
	date +%s
	;;
start)
	systemctl start --no-block mirror-pull.service
	;;
confined)
	# As the backup user, with its own key and ssh config, as mirror-pull reaches zero.
	check "the key runs no command of its own on zero" sh -c "
		out=\$(runuser -u backup -- ssh zero 'echo SIM-SHELL-OPENED; id' < /dev/null 2>&1); echo \"\$out\" | tail -n 2
		! echo \"\$out\" | grep -q SIM-SHELL-OPENED"
	check "sftp reads nothing through the key" sh -c "
		rm -f /tmp/sim-sftp; echo 'get /etc/passwd /tmp/sim-sftp' |
			runuser -u backup -- sftp -b - zero 2>&1 | tail -n 2; [ ! -e /tmp/sim-sftp ]"
	echo up > /tmp/sim-up && chown backup /tmp/sim-up
	check "an upload into the module is refused, read only" sh -c "
		out=\$(runuser -u backup -- rsync /tmp/sim-up mirror@zero::snapshots/sim-up 2>&1); echo \"\$out\" | tail -n 2
		echo \"\$out\" | grep -q 'read only'"
	mkdir -p /tmp/sim-empty && chown backup /tmp/sim-empty
	check "a --delete into the module is refused, read only" sh -c "
		out=\$(runuser -u backup -- rsync -r --delete /tmp/sim-empty/ mirror@zero::snapshots/ 2>&1); echo \"\$out\" | tail -n 2
		echo \"\$out\" | grep -q 'read only'"
	check "a path climbing out of the module with .. lists the module, never /etc" sh -c "
		out=\$(runuser -u backup -- rsync --list-only mirror@zero::snapshots/../../../etc/ 2>&1); echo \"\$out\" | tail -n 3
		! echo \"\$out\" | grep -qE ' (passwd|shadow|sudoers)\$'"
	check "nothing is read from outside it" sh -c "
		rm -f /tmp/sim-shadow; runuser -u backup -- rsync mirror@zero::snapshots/../../../etc/shadow /tmp/sim-shadow 2>&1 | tail -n 1
		[ ! -e /tmp/sim-shadow ]"
	check "no other module is served, and the module list names none" sh -c "
		out=\$(runuser -u backup -- rsync mirror@zero::other/ 2>&1); echo \"\$out\" | tail -n 1
		echo \"\$out\" | grep -qi 'unknown module' && [ -z \"\$(runuser -u backup -- rsync mirror@zero:: 2>/dev/null)\" ]"
	check "the key forwards nothing" sh -c "
		runuser -u backup -- ssh -v -N -L 127.0.0.1:2298:127.0.0.1:22 zero > /tmp/sim-fwd.log 2>&1 &
		p=\$!; sleep 4; timeout 5 bash -c 'exec 3<>/dev/tcp/127.0.0.1/2298; head -c 7 <&3' > /tmp/sim-banner 2>/dev/null
		sleep 1; kill \$p 2>/dev/null; wait \$p 2>/dev/null
		grep -m1 -i 'prohibited' /tmp/sim-fwd.log; [ ! -s /tmp/sim-banner ] && grep -qi 'prohibited' /tmp/sim-fwd.log"
	rm -rf /tmp/sim-up /tmp/sim-empty /tmp/sim-banner /tmp/sim-fwd.log
	;;
restore-user)
	check "sudoers lets the restore user run exactly its daemon" sh -c "
		sudo -n -U restore -l /usr/bin/setpriv --reuid=restore --regid=restore --init-groups --inh-caps=+dac_read_search --ambient-caps=+dac_read_search /usr/bin/rsync --server --daemon --config=/etc/rsyncd-restore.conf ."
	check "and nothing else: another daemon config, another user, a shell" sh -c "
		! sudo -n -U restore -l /usr/bin/setpriv --reuid=restore --regid=restore --init-groups --inh-caps=+dac_read_search --ambient-caps=+dac_read_search /usr/bin/rsync --server --daemon --config=/tmp/x . &&
		! sudo -n -U restore -l /usr/bin/setpriv --reuid=root --regid=root --init-groups --inh-caps=+dac_read_search --ambient-caps=+dac_read_search /usr/bin/rsync --server --daemon --config=/etc/rsyncd-restore.conf . &&
		! sudo -n -U restore -l /bin/bash"
	;;
caps) # <user>: the capabilities of that user's rsync daemon, while one runs
	for i in $(seq 1 30); do
		pids=$(pgrep -u "$2" -x rsync || true)
		[ -n "$pids" ] && break
		sleep 1
	done
	check "the $2 user's rsync daemon holds CAP_DAC_READ_SEARCH and nothing else" sh -c "
		[ -n '$pids' ] || { echo 'no rsync of $2 running'; exit 1; }
		for p in $pids; do
			grep -E '^(Uid|Cap(Inh|Prm|Eff|Amb)):' /proc/\$p/status | tr '\t' ' ' | tr -s ' ' | tr '\n' ';'; echo
			for c in CapPrm CapEff CapAmb; do
				[ \"\$(sed -n \"s/^\$c:[[:space:]]*//p\" /proc/\$p/status)\" = 0000000000000004 ] || exit 1
			done
			[ \"\$(awk '/^Uid:/ { print \$2 \$3 \$4 \$5 }' /proc/\$p/status)\" = \"\$(id -u $2)\$(id -u $2)\$(id -u $2)\$(id -u $2)\" ] || exit 1
		done"
	;;
locked)
	check "the array is locked, and received-backups not there" sh -c "
		! findmnt /media/mirror && ! test -e /dev/mapper/mirror && ! test -e $rb"
	t0=$(date +%s)
	systemctl start mirror-pull.service
	check "a pull against the locked array is skipped by its condition, not failed" sh -c "
		systemctl show -p ActiveState -p Result -p ConditionResult mirror-pull.service
		[ \"\$(systemctl show -p ConditionResult --value mirror-pull.service)\" = no ] &&
		[ \"\$(systemctl show -p Result --value mirror-pull.service)\" = success ] &&
		! systemctl is-active --quiet mirror-pull.timer"
	;;
unlocked)
	check "the unlock started the pull's timer, for 01:00 UTC" sh -c "
		for i in \$(seq 1 30); do systemctl is-active --quiet mirror-pull.timer && break; sleep 1; done
		systemctl show -p TimersCalendar --value mirror-pull.timer
		systemctl is-active --quiet mirror-pull.timer &&
		systemctl show -p TimersCalendar --value mirror-pull.timer | grep -q '01:00:00 UTC'"
	;;
cleanup) # <the snapshot to keep besides the newest>
	# Every snapshot dated a day apart at noon, the newest yesterday, then a snapshot taken
	# now by the service a good pull starts. With daily 2 and nothing else, snapper must
	# keep the one taken now and yesterday's, the newest two, and delete the rest.
	snaps | sed 's/^/    before: /'
	i=1
	for n in $(snaps | cut -d' ' -f1 | sort -rn); do
		sed -i "s:<date>.*</date>:<date>$(date -u -d "today 12:00 -$i day" '+%Y-%m-%d %H:%M:%S')</date>:" "$cur/.snapshots/$n/info.xml"
		i=$((i + 1))
	done
	keep=$(newest)
	cp /etc/snapper/configs/$cfg /root/sim-snapper-config
	snapper --no-dbus -c "$cfg" set-config TIMELINE_LIMIT_DAILY=2 TIMELINE_LIMIT_WEEKLY=0 TIMELINE_LIMIT_MONTHLY=0
	systemctl start mirror-snapshot.service
	snaps | sed 's/^/    after:  /'
	check "snapper's cleanup, at daily 2, kept the newest two: the one just taken and $keep" sh -c "
		$(declare -f snaps); cur=$cur
		[ \"\$(snaps | grep -c .)\" = 2 ] && [ \"\$(snaps | head -n 1 | cut -d' ' -f1)\" = $keep ] &&
		[ \"\$(snaps | tail -n 1 | cut -d' ' -f1)\" -gt $keep ]"
	cp /root/sim-snapper-config /etc/snapper/configs/$cfg
	;;
newest)
	newest
	;;
restore-db) # <three's snapshot> <Postgres image>
	src=$cur/.snapshots/$2/snapshot
	r=/media/mirror/restore
	rm -rf "$r" && mkdir -p "$r"
	docker rm -f sim-restore > /dev/null 2>&1
	check "a reflink copy of the db in three's snapshot $2" cp -a --reflink=always "$src/db" "$r/db"
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
	check "three's snapshot is untouched: read-only still" sh -c "
		btrfs property get -ts $src ro; [ \"\$(btrfs property get -ts $src ro)\" = ro=true ]"
	;;
esac
