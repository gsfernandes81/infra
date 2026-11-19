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
# A oneshot unit reads "activating" for as long as it runs, never "active", so `systemctl
# is-active` cannot tell a running pull; its ActiveState can.
running_now() {
	case "$(systemctl show -p ActiveState --value "$1")" in activating | deactivating) return 0 ;; esac
	return 1
}
# backup-snapshot.service is started by the pull's OnSuccess= as the pull ends, so it is
# waited for before anything is read.
settle() {
	local i
	sleep 2
	for i in $(seq 1 90); do
		! systemctl list-jobs --no-legend 2>/dev/null | grep -qE 'backup-(pull|snapshot)' &&
			! running_now backup-pull.service && ! running_now backup-snapshot.service && return 0
		sleep 2
	done
	return 1
}
rate() {
	local dir=/run/systemd/system/backup-pull.service.d
	rm -f "$dir"/sim-rate.conf
	if [ "$1" != default ]; then
		mkdir -p "$dir"
		printf '[Service]\nEnvironment=BACKUP_PULL_BWLIMIT=%s\n' "$1" > "$dir/sim-rate.conf"
	fi
	systemctl daemon-reload
}
# The units' own lines since <time>: every line rsync or the two units wrote about an error
# or a result, then the last few, which hold rsync's statistics.
journal() {
	journalctl --no-pager -o cat --since "@$1" -u backup-pull.service -u backup-snapshot.service > /root/sim-journal
	grep -E '^rsync|^backup-(pull|snapshot):|status=' /root/sim-journal | head -n 20 | sed 's/^/    | /'
	grep -E '^(Total bytes|Literal data|Number of regular files transferred)' /root/sim-journal | tail -n 3 | sed 's/^/    | /'
}

case "${1:?step}" in
layout)
	check "received-backups and immich are root's, mode 755" sh -c "
		s=\$(stat -c '%U %a' $rb $d | sort -u); echo \"\$s\"; [ \"\$s\" = 'root 755' ]"
	check "current is a subvolume, the backup user's, mode 700" sh -c "
		stat -c '%i %U %a' $cur; [ \"\$(stat -c '%i %U %a' $cur)\" = '256 backup 700' ]"
	check "current/.snapshots is a subvolume, root's, mode 754, holding no snapshot yet" sh -c "
		stat -c '%i %U %a' $cur/.snapshots; [ \"\$(stat -c '%i %U %a' $cur/.snapshots)\" = '256 root 754' ] &&
		[ -z \"\$(ls -A $cur/.snapshots)\" ]"
	check "state is the backup user's, mode 700" sh -c "
		[ \"\$(stat -c '%U %a' $d/state)\" = 'backup 700' ]"
	check "snapper reads three's config with --no-dbus" snapper --no-dbus -c "$cfg" list
	;;
key)
	# As hosts/three/leap/README.md § The backup has the owner make it. The public half is
	# printed last, for the runner to put in zero's key line.
	ssh-keygen -q -t ed25519 -N '' -C 'three backup-pull' -f /home/backup/.ssh/zero-pull &&
		chown backup:backup /home/backup/.ssh/zero-pull /home/backup/.ssh/zero-pull.pub &&
		stat -c '%U %a %n' /home/backup/.ssh/zero-pull >&2 &&
		cut -d' ' -f1,2 /home/backup/.ssh/zero-pull.pub
	;;
lan)
	# The README's runtime drop-in for the first pull over the LAN: no rate limit, until the
	# next boot or its removal.
	mkdir -p /run/systemd/system/backup-pull.service.d
	printf '[Service]\nEnvironment=BACKUP_PULL_BWLIMIT=0\n' > /run/systemd/system/backup-pull.service.d/lan.conf
	systemctl daemon-reload
	systemctl show -p Environment --value backup-pull.service
	;;
rate) # <KiB/s | default>, a second drop-in over the README's, for the cut pulls
	rate "$2"
	;;
pull) # <expected zero snapshot> <expected count after> : a pull that must succeed
	t0=$(date +%s)
	snaps > /root/sim-snaps-before
	systemctl start backup-pull.service
	settle || echo "FAIL the pull or its snapshot did not finish in two minutes"
	journal "$t0"
	check "the pull of zero's snapshot $2 succeeded" sh -c "
		[ \"\$(systemctl show -p Result --value backup-pull.service)\" = success ] &&
		journalctl --no-pager -o cat --since @$t0 -u backup-pull.service | grep -q 'pulled snapshot $2 of '"
	check "three took one snapshot after it, 'pulled $2', and holds $3" sh -c "
		$(declare -f snaps); cur=$cur; snaps
		[ \"\$(snaps | grep -c .)\" = $3 ] && [ \"\$(snaps | tail -n 1 | cut -d' ' -f2-)\" = 'pulled $2' ] &&
		[ \"\$(systemctl show -p Result --value backup-snapshot.service)\" = success ]"
	check "last-pulled names snapshot $2, root's" sh -c "
		cat $d/last-pulled; stat -c '%U %a' $d/last-pulled
		[ \"\$(cut -d' ' -f1 $d/last-pulled)\" = $2 ] && [ \"\$(stat -c %U $d/last-pulled)\" = root ]"
	check "every snapshot three held before is still there" sh -c "
		$(declare -f snaps); cur=$cur; snaps > /root/sim-snaps-after
		! grep -vxFf /root/sim-snaps-after /root/sim-snaps-before"
	;;
nothing-new) # <count>
	t0=$(date +%s)
	lp=$(cat "$d/last-pulled")
	systemctl start backup-pull.service
	settle || true
	journal "$t0" 4
	check "a pull with nothing new copies nothing and takes no snapshot" sh -c "
		$(declare -f snaps); cur=$cur
		journalctl --no-pager -o cat --since @$t0 -u backup-pull.service | grep -q 'nothing new' &&
		[ \"\$(snaps | grep -c .)\" = $2 ] && [ \"\$(cat $d/last-pulled)\" = '$lp' ] &&
		[ ! -e $d/state/pulled ] &&
		[ \"\$(systemctl show -p ConditionResult --value backup-snapshot.service)\" = no ]"
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
	# The backup user cannot set the xattr that keeps an owner on a symlink, so rsync may
	# keep the link as a plain file holding its target, its type in the xattr; or it is a
	# symlink, munged. Either way no link on three leads anywhere.
	check "a symlink zero sent leads nowhere on three: a plain file, or a munged link" sh -c "
		f=$cur/data/library/link.jpg; stat -c '%F' \$f
		x=\$(python3 -c 'import os,sys; print(os.getxattr(sys.argv[1], \"user.rsync.%stat\", follow_symlinks=False).decode())' \$f 2>&1); echo \"xattr: \$x\"
		[ ! -e /rsyncd-munged ] || exit 1
		if [ -L \$f ]; then t=\$(readlink \$f); echo \"a symlink to \$t\"; [ \"\$t\" = /rsyncd-munged/a.jpg ]
		else echo \"a plain file holding: \$(cat \$f)\"; [ -f \$f ] && case \$x in 120777\ *) ;; *) exit 1 ;; esac
		fi"
	;;
changes) # <before ctime of big.bin>
	check "a file added on zero arrived, one deleted is gone from current and kept in the first snapshot" sh -c "
		ls $cur/data/library
		first=\$(ls $cur/.snapshots | sort -n | head -n 1)
		[ -e $cur/data/library/c.jpg ] && [ ! -e $cur/data/library/b.jpg ] &&
		[ -e $cur/.snapshots/\$first/snapshot/data/library/b.jpg ]"
	check "big.bin, unchanged on zero, was not written again" sh -c "
		s=\$(stat -c '%i:%Z' $cur/data/library/big.bin); echo \"before: $2; now: \$s\"; [ \"\$s\" = '$2' ]"
	;;
ctime)
	stat -c '%i:%Z' "$cur/data/library/big.bin"
	;;
delete-calibration)
	# What --delete would do to three's snapshots without backup-pull's exclude and protect
	# filters: a dry run of the same transfer with them left out. As root, since the backup
	# user cannot enter .snapshots (root's, 754), which is a second guard. It must show
	# rsync deleting inside .snapshots, or the checks after the real pulls prove nothing.
	n=$(sed -n 's/ .*//p' "$d/last-pulled")
	rsync -n -i -aHAX --numeric-ids --fake-super --munge-links --delete \
		-e 'ssh -F /home/backup/.ssh/config -o UserKnownHostsFile=/home/backup/.ssh/known_hosts' \
		"backup@zero::snapshots/$n/snapshot/" "$cur/" > /root/sim-delete.log 2>&1
	check "calibration: without the filters, --delete would empty three's .snapshots" sh -c "
		grep -m3 'deleting .*\.snapshots/' /root/sim-delete.log || tail -n 5 /root/sim-delete.log
		grep -q 'deleting .*\.snapshots/' /root/sim-delete.log"
	;;
running) # waits until a pull is under way, its first bytes of <file> in current/
	for i in $(seq 1 120); do
		if running_now backup-pull.service && [ -s "$cur/$2" ]; then
			echo "the pull is under way: $(stat -c %s "$cur/$2") bytes of $2 so far"
			exit 0
		fi
		sleep 1
	done
	echo "the pull never got under way: $(systemctl show -p ActiveState,Result backup-pull.service | tr '\n' ' ')"
	exit 1
	;;
failed) # <since> <exit status, or any> <count> : a pull that must have failed, leaving nothing
	settle || true
	journal "$2" 6
	check "the pull failed with exit $3" sh -c "
		systemctl show -p Result -p ExecMainStatus backup-pull.service
		st=\$(systemctl show -p ExecMainStatus --value backup-pull.service)
		[ \"\$(systemctl show -p Result --value backup-pull.service)\" = exit-code ] &&
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
	systemctl start --no-block backup-pull.service
	;;
confined)
	# As the backup user, with its own key and ssh config, as backup-pull reaches zero.
	check "the key runs no command of its own on zero" sh -c "
		out=\$(runuser -u backup -- ssh backup@zero 'echo SIM-SHELL-OPENED; id' < /dev/null 2>&1); rc=\$?; echo \"exit \$rc: \$out\" | tail -n 2
		! echo \"\$out\" | grep -qiE 'SIM-SHELL-OPENED|permission denied'"
	check "sftp reads nothing through the key" sh -c "
		rm -f /tmp/sim-sftp; out=\$(echo 'get /etc/passwd /tmp/sim-sftp' | runuser -u backup -- sftp -b - backup@zero 2>&1)
		echo \"\$out\" | tail -n 2; [ ! -e /tmp/sim-sftp ] && ! echo \"\$out\" | grep -qi 'permission denied'"
	echo up > /tmp/sim-up && chown backup /tmp/sim-up
	check "an upload into the module is refused, read only" sh -c "
		out=\$(runuser -u backup -- rsync -e ssh /tmp/sim-up backup@zero::snapshots/sim-up 2>&1); echo \"\$out\" | tail -n 2
		echo \"\$out\" | grep -q 'read only'"
	mkdir -p /tmp/sim-empty && chown backup /tmp/sim-empty
	check "a --delete into the module is refused, read only" sh -c "
		out=\$(runuser -u backup -- rsync -e ssh -r --delete /tmp/sim-empty/ backup@zero::snapshots/ 2>&1); echo \"\$out\" | tail -n 2
		echo \"\$out\" | grep -q 'read only'"
	# Each must be refused for the module's own reason, read back from rsync, never for a
	# failure to connect at all.
	check "a path climbing out of the module with .. is held inside it, never /etc" sh -c "
		out=\$(runuser -u backup -- rsync -e ssh --list-only backup@zero::snapshots/../../../etc/ 2>&1); echo \"\$out\" | tail -n 3
		echo \"\$out\" | grep -qE 'No such file|failed' && ! echo \"\$out\" | grep -qE ' (passwd|shadow|sudoers)\$'"
	check "nothing is read from outside it" sh -c "
		rm -f /tmp/sim-shadow; out=\$(runuser -u backup -- rsync -e ssh backup@zero::snapshots/../../../etc/shadow /tmp/sim-shadow 2>&1)
		echo \"\$out\" | tail -n 2; echo \"\$out\" | grep -q 'No such file' && [ ! -e /tmp/sim-shadow ]"
	check "no other module is served, and the module list names none" sh -c "
		out=\$(runuser -u backup -- rsync -e ssh backup@zero::other/ 2>&1); echo \"\$out\" | tail -n 1
		echo \"\$out\" | grep -qi 'unknown module' &&
		runuser -u backup -- rsync -e ssh backup@zero:: > /tmp/sim-modules 2>&1; cat /tmp/sim-modules
		! grep -q snapshots /tmp/sim-modules"
	# A remote forward is asked for at once, so sshd's refusal comes back on its own.
	check "the key forwards nothing" sh -c "
		out=\$(timeout 30 runuser -u backup -- ssh -N -o ExitOnForwardFailure=yes -R 127.0.0.1:2297:127.0.0.1:22 backup@zero < /dev/null 2>&1)
		rc=\$?; echo \"exit \$rc: \$out\" | tail -n 2
		[ \$rc != 0 ] && [ \$rc != 124 ] && echo \"\$out\" | grep -qi 'forwarding failed'"
	rm -rf /tmp/sim-up /tmp/sim-empty /tmp/sim-modules
	;;
restore-user)
	# Leap's own sudoers lets every user run anything with root's password (targetpw), so
	# the rule that matters is what runs with none. Asked of sudo itself, as the restore user.
	cmd='/usr/bin/setpriv --reuid=restore --regid=restore --init-groups --inh-caps=+dac_read_search --ambient-caps=+dac_read_search /usr/bin/rsync --server --daemon --config=/etc/rsyncd-restore.conf .'
	check "the restore user runs its daemon through sudo with no password" sh -c "
		out=\$(runuser -u restore -- sudo -n $cmd < /dev/null 2>&1); echo \"\$out\" | tail -n 2
		! echo \"\$out\" | grep -qiE 'password is required|not allowed|may not run'"
	check "and nothing else without a password: another config, another user, a shell" sh -c "
		for c in '${cmd/rsyncd-restore.conf/rsyncd-other.conf}' '${cmd//reuid=restore/reuid=root}' /bin/bash; do
			out=\$(runuser -u restore -- sudo -n \$c < /dev/null 2>&1); echo \"\$c: \$(echo \"\$out\" | tail -n 1)\"
			echo \"\$out\" | grep -qi 'password is required' || exit 1
		done"
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
	# An earlier failed run leaves its result on the unit until something resets it.
	systemctl reset-failed backup-pull.service backup-snapshot.service 2>/dev/null
	systemctl start backup-pull.service
	check "a pull against the locked array is skipped by its condition, not failed" sh -c "
		systemctl show -p ActiveState -p Result -p ConditionResult backup-pull.service
		[ \"\$(systemctl show -p ConditionResult --value backup-pull.service)\" = no ] &&
		[ \"\$(systemctl show -p Result --value backup-pull.service)\" = success ] &&
		! systemctl is-active --quiet backup-pull.timer"
	;;
unlocked)
	check "the unlock started the pull's timer, for 01:00 UTC" sh -c "
		for i in \$(seq 1 30); do systemctl is-active --quiet backup-pull.timer && break; sleep 1; done
		systemctl show -p TimersCalendar --value backup-pull.timer
		systemctl is-active --quiet backup-pull.timer &&
		systemctl show -p TimersCalendar --value backup-pull.timer | grep -q '01:00:00 UTC'"
	;;
cleanup) # <the snapshot to keep besides the newest>
	# Every snapshot dated a day apart at noon, the newest yesterday, then a snapshot taken
	# now by the service a good pull starts. With daily 2 and nothing else, snapper must
	# keep the one taken now and yesterday's, the newest two, and delete the rest.
	snaps | sed 's/^/    before: /'
	i=1
	for n in $(snaps | cut -d' ' -f1 | sort -rn); do
		sed -i "s|<date>.*</date>|<date>$(date -u -d "@$(($(date -u +%s) / 86400 * 86400 + 43200 - i * 86400))" '+%Y-%m-%d %H:%M:%S')</date>|" "$cur/.snapshots/$n/info.xml"
		i=$((i + 1))
	done
	keep=$(newest)
	cp /etc/snapper/configs/$cfg /root/sim-snapper-config
	snapper --no-dbus -c "$cfg" set-config TIMELINE_LIMIT_DAILY=2 TIMELINE_LIMIT_WEEKLY=0 TIMELINE_LIMIT_MONTHLY=0
	systemctl start backup-snapshot.service
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
