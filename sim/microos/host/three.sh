# shellcheck shell=bash
# shellcheck disable=SC2034,SC2054  # read by run-host.sh; commas belong to qemu
# three's stand-ins for sim/microos/run-host.sh; sourced, never run.
#
# three is a NEW host, so its stick is the one `make-stick --new` builds: no tunnel
# credentials, .env, secrets or volumes (run-host.sh leaves them out for a host with no
# tunnel config). After the first boot, the hooks below do what the visit does next: put a
# tunnel in place as server-create-host-tunnel.yml and install-system-file would, format
# the drive with make-mirror, and unlock it with the README's own command. Then the runner
# stands in for zero, and three pulls zero's backup from it (sim_backup, below).

# zero's three values in three's files, swapped on the stick for the run's own: zero's host
# key, which the runner's stand-in for zero answers with (zero-known-hosts); zero's restore
# key, which the stand-in reads its backups back with (restore-authorized-keys); and zero's
# tailnet address, which is both where three's pull connects (backup-ssh-config) and where
# a restore must come from (from=). qemu's host address on this network is both: the VM
# reaches the runner there, and the runner's connections into the VM arrive from it.
# Everything else in the files is the tracked text, as the box carries it.
rm -f zero-host zero-host.pub restore-key restore-key.pub
ssh-keygen -q -t ed25519 -N '' -C 'sim zero host' -f zero-host
ssh-keygen -q -t ed25519 -N '' -C 'sim zero restore' -f restore-key
zero_addr=$(sed -n 's/^[[:space:]]*HostName //p' "$repo/hosts/three/leap/system/backup-ssh-config")
declare -A standin=(
	[FILL-FROM-ZERO-HOST-KEY]="$(cut -d' ' -f1,2 zero-host.pub)"
	[FILL-FROM-ZERO-RESTORE-KEY]="$(cat restore-key.pub)"
	["$zero_addr"]=192.168.86.1
)

# qemu's user network on the UK subnet, so three's static address answers.
sim_net=192.168.86.0/24
sim_gateway=192.168.86.1
sim_dns=192.168.86.3
sim_address=192.168.86.103
sim_dhcp_address=192.168.86.15

tunnel_id=3a3a3a3a-0000-4000-8000-000000000003

# syncthing-three requires no name from .env; anything asked for gets a made-up value.
standin_env() { openssl rand -hex 16; }
deployments=(syncthing-three)
volumes=()

# The WD Red, new and blank, on USB as the Argon's bridge puts it. Its size is how the
# hooks find it on the box; make-mirror formats it there.
mirror_bytes=$((1536 * 1024 * 1024))
make_disks() {
	truncate -s "$mirror_bytes" mirror.img
	echo "a blank $((mirror_bytes / 1024 / 1024))M drive for the array"
}
disk_args=(
	-drive file="$PWD/mirror.img",if=none,id=mirror,format=raw
	-device usb-storage,bus=xhci.0,drive=mirror
)

luks_password=$(openssl rand -hex 12)

# The unlock, exactly as hosts/three/leap/README.md § Unlocking gives it, typed at a
# terminal: unlock.py answers sudo's prompt and then systemd's.
sim_unlock() {
	if SIM_SUDO_PW=$password SIM_LUKS_PW=$luks_password python3 -I "$here/host/unlock.py" \
		-i key -p "$(cat port)" -o StrictHostKeyChecking=no -o UserKnownHostsFile=known \
		-o BatchMode=yes gavin@127.0.0.1 \
		-- 'sudo systemctl start systemd-cryptsetup@mirror.service; and sudo systemctl start media-mirror.mount' \
		> unlock.log 2>&1; then
		echo "PASS the README's command unlocks and mounts the array"
	else
		echo "FAIL the README's command did not unlock the array:"
		tail -n 15 unlock.log | sed 's/^/    /'
	fi
	# The mount starts Docker, and the first run saw the next new ssh connection fail as it
	# did (exit 255). So the first attempt's own words are kept, ssh is waited for and how
	# long it was away reported, and if it never returns the console shows the firewall and
	# Docker's start.
	echo "the first ssh after the unlock: $(ssh -i key -p "$(cat port)" -o StrictHostKeyChecking=no \
		-o UserKnownHostsFile=known -o BatchMode=yes -o ConnectTimeout=5 gavin@127.0.0.1 true 2>&1 &&
		echo answered || true)"
	if ! wait_gavin static; then
		echo "the console's view of the firewall and Docker after the unlock:"
		python3 -I "$here/serial-login.py" serial.sock "$root_password" "$(cat <<'DIAG'
firewall-cmd --state; firewall-cmd --get-active-zones; firewall-cmd --list-all
nft list ruleset | head -n 120
journalctl -b --no-pager -u docker -u firewalld | tail -n 60
ss -tlnp | head -n 20; systemctl --no-pager status sshd | head -n 12
DIAG
)" || tail -n 60 serial.log
		return 1
	fi
}

sim_after_firstboot() {
	local dev
	echo "===== three's tunnel, as server-create-host-tunnel.yml and install-system-file leave it"
	# Stand-in credentials, and a config in the shape of every host's, then the start the
	# README gives once the config is in place.
	if ! { printf '%s\n' "$password"; cat <<TUNNEL; } | ssh_as gavin@127.0.0.1 "sudo -S -p '' bash -s" 2>&1 | sed 's/^/    /'; then
set -e
install -d -m 755 /etc/cloudflared
( umask 077; printf '{"AccountTag":"sim","TunnelSecret":"c2lt","TunnelID":"$tunnel_id"}\n' > /etc/cloudflared/three.json )
printf '%s\n' 'tunnel: $tunnel_id' 'credentials-file: /etc/cloudflared/three.json' \
	'metrics: 127.0.0.1:20241' 'ingress:' '  - hostname: ssh-three.sim.invalid' \
	'    service: ssh://127.0.0.1:22' '  - service: http_status:404' > /etc/cloudflared/config.yml
systemctl start --no-block cloudflared
TUNNEL
		echo "FAIL could not put the stand-in tunnel in place"
	fi
	sleep 5
	if printf '%s\n' "$password" | ssh_as gavin@127.0.0.1 \
		"sudo -S -p '' systemctl show -p ActiveState --value cloudflared" | grep -qE '^(active|activating)$'; then
		echo "PASS cloudflared starts once its config is in place"
	else
		echo "FAIL cloudflared did not start once its config was in place"
	fi

	echo "===== the array, made by make-mirror and unlocked as the README says"
	dev=$(ssh_as gavin@127.0.0.1 "lsblk -dnbro NAME,SIZE" | awk -v s="$mirror_bytes" '$2 == s { print "/dev/" $1 }' || true)
	echo "the blank drive is ${dev:-not found}"
	# The script under test, not the box's checkout, which is main's until the deploy stage.
	ssh_as gavin@127.0.0.1 "cat > /tmp/make-mirror" < "$repo/hosts/three/leap/make-mirror" ||
		echo "FAIL could not copy make-mirror to the box"
	if { printf '%s\n' "$password" "$dev" "$luks_password" "$luks_password"; } |
		ssh_as gavin@127.0.0.1 "sudo -S -p '' bash /tmp/make-mirror $dev" > make-mirror.log 2>&1; then
		echo "PASS make-mirror made the array"
	else
		echo "FAIL make-mirror could not make the array"
	fi
	sed 's/^/    /' make-mirror.log
	if { printf '%s\n' "$password" "$dev"; } |
		ssh_as gavin@127.0.0.1 "sudo -S -p '' bash /tmp/make-mirror $dev" > make-mirror-again.log 2>&1; then
		echo "FAIL make-mirror erased a drive that already holds the array"
	elif grep -q 'not new\|mirror-luks exists' make-mirror-again.log; then
		echo "PASS make-mirror refuses a drive that is not new"
	else
		echo "FAIL make-mirror refused for another reason: $(tail -n 1 make-mirror-again.log)"
	fi
	# A FAIL is already printed; returning keeps the run from dying silently under set -e.
	sim_unlock || return 0
	as_root three-unlocked.sh first
	sim_backup
}

# ── zero's backup, pulled by three from the runner standing in for zero ──────
# The runner plays zero with a small btrfs on a loop file, laid out as zero's array is once
# the move in plans/visit-runbook.md is done: the subvolume immich, mounted on its own as
# zero mounts /media/immich, holding data (thumbs and encoded-video nested subvolumes) and
# db, where a Postgres container writes throughout, and .snapshots, the subvolume snapper
# keeps its snapshots in. Zero itself is an Alpine container of zero's release, privileged
# and on the runner's network, with that mount at /media/immich: it installs snapper from
# edge/testing, util-linux's setpriv, sudo and rsync as hosts/zero/system/README.md has the
# owner do, makes the mirror user the same way, installs zero's tracked files at the paths
# their headers name, and serves three's key with its own sshd on the runner's port 22,
# which the VM reaches at qemu's host address. Its snapshots are the tracked hourly
# script's, run by hand.
pg_image=docker.io/library/postgres:16-alpine
zero_image=$(sed -n 's/^FROM //p' "$repo/sim/alpine/host/Dockerfile")
ztop=$PWD/zero-top
zimm=$PWD/zero-immich
zloop=

fail_or_skip() {
	if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "FAIL $*"; else echo "SKIP $*"; fi
}
# A command in the stand-in for zero, as root there.
zx() { sudo docker exec sim-zero sh -euc "$1"; }
# The stand-in's newest finished snapshot: the highest number with an info.xml.
znewest() {
	sudo find "$zimm/.snapshots" -mindepth 2 -maxdepth 2 -name info.xml -printf '%h\n' 2> /dev/null |
		sed 's:.*/::' | sort -n | tail -n 1
}
# zero's hourly snapshot, by the tracked script, as root's cron would run it.
zsnap() {
	if zx /etc/periodic/hourly/snapper-immich; then
		echo "zero took snapshot $(znewest)"
	else
		echo "FAIL zero's hourly script did not take a snapshot"
	fi
}
# The same tree on both sides: zero's snapshot, read on the runner, and three's newest
# snapshot of its copy, read back through --fake-super.
same_tree() {
	local a b n
	n=$(as_root three-backup.sh newest | tail -n 1)
	a=$(sudo bash "$here/host/tree-hash.sh" "$zimm/.snapshots/$1/snapshot" 2>&1) || true
	b=$(as_root tree-hash.sh --fake-super "/media/mirror/received-backups/immich/current/.snapshots/$n/snapshot" 2>&1) || true
	if [ -n "$a" ] && [ "$a" = "$b" ]; then
		echo "PASS zero's snapshot $1 and three's snapshot $n are the same tree: every path, owner, mode, size and content"
	else
		echo "FAIL zero's snapshot $1 and three's snapshot $n differ: zero's hashes to ${a:-nothing}, three's to ${b:-nothing}" |
			head -c 2000
		echo
	fi
}

# zero's array after the move, in miniature. Called in an || list, where set -e does not
# reach, so each step checks its own result.
zero_make() {
	sudo umount "$zimm" "$ztop" 2> /dev/null || true
	rm -f zero.img && truncate -s 2G zero.img && mkfs.btrfs -q -L zero-sim zero.img || return 1
	mkdir -p "$ztop" "$zimm" && zloop=$(sudo losetup -f --show zero.img) || return 1
	sudo mount -o noatime "$zloop" "$ztop" || return 1
	sudo bash -s "$ztop" <<'MAKE' || return 1
set -e
t=$1
btrfs subvolume create "$t/immich" > /dev/null
mkdir -p "$t/immich/data/library" "$t/immich/data/upload" "$t/immich/data/backups" "$t/immich/data/profile"
btrfs subvolume create "$t/immich/data/thumbs" > /dev/null
btrfs subvolume create "$t/immich/data/encoded-video" > /dev/null
echo thumb > "$t/immich/data/thumbs/t.webp"
echo video > "$t/immich/data/encoded-video/v.mp4"
install -d -m 700 "$t/immich/db"
echo one > "$t/immich/data/library/a.jpg"
chown 1000:1000 "$t/immich/data/library/a.jpg" && chmod 640 "$t/immich/data/library/a.jpg"
echo two > "$t/immich/data/library/b.jpg"
ln -s a.jpg "$t/immich/data/library/link.jpg"
head -c 8M /dev/urandom > "$t/immich/data/library/big.bin"
echo dump > "$t/immich/data/backups/immich-db-backup.sql.gz"
# As the move makes it: a subvolume, so no snapshot holds the ones before it, root's, 750.
btrfs subvolume create "$t/immich/.snapshots" > /dev/null
chmod 750 "$t/immich/.snapshots"
MAKE
	sudo btrfs subvolume list "$ztop" | sed 's/^/    /'
	sudo mount -o subvol=immich,noatime "$zloop" "$zimm"
}

# A Postgres on immich/db: 100 rows, then a writer that never stops, so every snapshot from
# here on catches it mid-write, as zero's snapshots catch Immich's.
zero_postgres() {
	local i l
	sudo docker rm -f sim-pg > /dev/null 2>&1 || true
	sudo docker pull -q "$pg_image" > /dev/null || true
	if ! sudo docker run -d --name sim-pg -e POSTGRES_PASSWORD=sim \
		-v "$zimm/db:/var/lib/postgresql/data" "$pg_image" > /dev/null; then
		echo "FAIL could not start Postgres on the runner"
		return 1
	fi
	for i in $(seq 1 60); do
		l=$(sudo docker logs sim-pg 2>&1 || true)
		if grep -q 'PostgreSQL init process complete' <<<"$l" &&
			sudo docker exec sim-pg pg_isready -U postgres -q; then
			break
		fi
		sleep 2
	done
	if sudo docker exec sim-pg psql -U postgres -qc \
		'create table t (id serial primary key, at timestamptz default now()); insert into t (at) select now() from generate_series(1, 100)' &&
		sudo docker exec -d sim-pg psql -U postgres -qc \
			'do $$ begin loop insert into t default values; commit; perform pg_sleep(0.01); end loop; end $$'; then
		echo "Postgres on zero's immich/db holds 100 rows, and a writer adds more throughout"
	else
		echo "FAIL could not write the rows into zero's Postgres:"
		sudo docker logs sim-pg 2>&1 | tail -n 10 | sed 's/^/    /'
		return 1
	fi
}

# The stand-in for zero, set up as hosts/zero/system/README.md § The backup has the owner
# set up zero, with three's backup key, made on three, in the mirror line.
zero_up() {
	local key=$1 f
	sudo docker rm -f sim-zero > /dev/null 2>&1 || true
	# Port 22 on the runner is where three's pull connects, through qemu's host address.
	if sudo ss -Hltn 'sport = :22' | grep -q .; then
		echo "the runner's own sshd holds port 22; stopping it for zero's stand-in"
		sudo systemctl stop ssh.socket ssh.service 2> /dev/null || true
	fi
	sudo docker run -d --name sim-zero --privileged --network host \
		-v "$zimm:/media/immich" -v "$repo:/repo:ro" "$zero_image" sleep infinity > /dev/null || return 1
	echo "zero's stand-in: $zero_image"
	zx 'apk add --quiet openssh sudo rsync setpriv btrfs-progs' || return 1
	# snapper as the README installs it, from edge/testing by its full name; apk checks its
	# signature. The SHA-256 the README pins is aarch64's, zero's; this runner is x86_64, so
	# alpine-sim.yml checks that line, on arm64.
	zx 'cd /root && wget -q "https://dl-cdn.alpinelinux.org/alpine/edge/testing/$(apk --print-arch)/snapper-0.13.1-r0.apk" &&
		apk add --quiet ./snapper-0.13.1-r0.apk && apk add --quiet snapper=0.13.1-r0' || return 1
	zx 'snapper --version | head -n 1; /bin/setpriv --version; rsync --version | head -n 1; sudo -V | head -n 1' | sed 's/^/    /'
	# The mirror user as the README makes it. BusyBox's adduser locks the account with !,
	# and sshd refuses a key for a locked account, so * replaces it: no password, not locked.
	zx 'addgroup -S mirror && adduser -S -D -H -h /home/mirror -s /bin/sh -G mirror mirror &&
		sed -i "s/^mirror:![^:]*:/mirror:*:/" /etc/shadow && install -d -m 755 /home/mirror /home/mirror/.ssh' || return 1
	# zero's tracked files, each at the path its header names, three's address and key in
	# the mirror line swapped for the runner's own, sudoers checked as install-system-file
	# checks it.
	for f in snapper-config-immich snapper-sysconfig snapper-immich sudoers-mirror rsyncd-mirror.conf \
		mirror-authorized-keys sshd-infra.conf; do
		zx "f=/repo/hosts/zero/system/$f
			p=\$(sed -n 's/^# infra-path:[[:space:]]*//p' \$f); n=\$(sed -n 's/^# infra-name:[[:space:]]*//p' \$f)
			m=\$(sed -n 's/^# infra-mode:[[:space:]]*//p' \$f)
			sed -e 's/from=\"[^\"]*\"/from=\"127.0.0.1\"/' -e 's|FILL-FROM-THREE-BACKUP-KEY|$key three mirror-pull|' \$f > /tmp/f
			install -D -m \$m /tmp/f \$p/\$n
			case \$p in /etc/sudoers.d) visudo -cf \$p/\$n ;; esac" || { echo "FAIL could not install zero's $f"; return 1; }
	done
	zx 'grep -v "^#" /home/mirror/.ssh/authorized_keys | cut -c1-80' | sed 's/^/    mirror line: /'
	sudo docker cp zero-host sim-zero:/etc/ssh/ssh_host_ed25519_key
	zx 'chown root:root /etc/ssh/ssh_host_ed25519_key && chmod 600 /etc/ssh/ssh_host_ed25519_key &&
		ssh-keygen -y -f /etc/ssh/ssh_host_ed25519_key > /etc/ssh/ssh_host_ed25519_key.pub &&
		/usr/sbin/sshd -t && /usr/sbin/sshd -E /var/log/sshd.log -o ListenAddress=127.0.0.1 -o HostKey=/etc/ssh/ssh_host_ed25519_key' || return 1
	# zero's restore key, as server-create-restore-key.yml leaves it in /root/.ssh.
	zx 'install -d -m 700 /root/.ssh'
	sudo docker cp restore-key sim-zero:/root/.ssh/restore
	zx 'chown root:root /root/.ssh/restore && chmod 600 /root/.ssh/restore'
}

# The checks only zero's side can make: its sudoers and the capabilities of its daemon.
zero_confined() {
	local cmd='/bin/setpriv --reuid=mirror --regid=mirror --init-groups --inh-caps=+dac_read_search --ambient-caps=+dac_read_search /usr/bin/rsync --server --daemon --config=/etc/rsyncd-mirror.conf .'
	if zx "sudo -n -U mirror -l $cmd" > /dev/null 2>&1; then
		echo "PASS zero's sudoers lets the mirror user run exactly its daemon"
	else
		echo "FAIL zero's sudoers does not allow the mirror user its daemon"
	fi
	if zx "sudo -n -U mirror -l ${cmd/rsyncd-mirror.conf/rsyncd-other.conf}" > /dev/null 2>&1 ||
		zx "sudo -n -U mirror -l ${cmd//reuid=mirror/reuid=root}" > /dev/null 2>&1 ||
		zx 'sudo -n -U mirror -l /bin/sh' > /dev/null 2>&1; then
		echo "FAIL zero's sudoers allows the mirror user something else"
	else
		echo "PASS and nothing else: another daemon config, another user, a shell"
	fi
}
# The mirror user's rsync processes on the stand-in, from /proc: BusyBox's pgrep found none
# while one ran.
zero_daemons() {
	zx 'u=$(id -u mirror); for d in /proc/[0-9]*; do
		[ "$(cat $d/comm 2>/dev/null)" = rsync ] && [ "$(awk "/^Uid:/ { print \$2 }" $d/status 2>/dev/null)" = "$u" ] && echo ${d#/proc/}
	done; true'
}
zero_caps() {
	local pids p st i
	for i in $(seq 1 30); do
		pids=$(zero_daemons)
		[ -n "$pids" ] && break
		sleep 1
	done
	[ -n "$pids" ] || { echo "FAIL no rsync daemon of the mirror user ran on zero to read"; return 0; }
	for p in $pids; do
		st=$(zx "grep -E '^(Uid|Gid|Cap(Inh|Prm|Eff|Amb)):' /proc/$p/status" | tr '\t' ' ' | tr -s ' ' | tr '\n' ';') || true
		echo "    zero's daemon, pid $p: $st"
		case "$st" in
		*"CapPrm: 0000000000000004;"*"CapEff: 0000000000000004;"*"CapAmb: 0000000000000004;"*) ;;
		*) echo "FAIL zero's rsync daemon holds other capabilities"; return 0 ;;
		esac
		case "$st" in
		"Uid: $(zx 'id -u mirror') "*) ;;
		*) echo "FAIL zero's rsync daemon is not running as the mirror user"; return 0 ;;
		esac
	done
	echo "PASS zero's rsync daemon runs as the mirror user with CAP_DAC_READ_SEARCH and nothing else"
}
zero_kill_daemon() {
	local pids
	pids=$(zero_daemons)
	# Killed by pid from a list made first, never by a pattern (CLAUDE.md § Shell traps).
	[ -n "$pids" ] && { zx "kill $(echo "$pids" | tr '\n' ' ')" || true; }
	echo "killed zero's daemon: ${pids:-none was running}" | tr '\n' ' '
	echo
}

sim_backup() {
	local key n n2 since before pg_ok=no restore_dir out rc link want
	# Every step reports its own PASS or FAIL, so a step that fails must not end the stage
	# under run-host.sh's set -e and leave the later checks unrun. This runs in the report
	# pipeline's subshell, so the setting ends with it.
	set +e
	echo "===== zero's backup, pulled by three from the runner standing in for zero"
	if ! command -v docker > /dev/null; then
		fail_or_skip "no docker on the runner for zero's stand-in"
		return 0
	fi
	as_root three-backup.sh layout
	# three's key to zero, made on three as its README says; the public half goes into
	# zero's mirror line, as the owner sends it to the infra agent.
	key=$(as_root three-backup.sh key 2> key.err | tail -n 1)
	sed 's/^/    /' key.err
	case "$key" in
	"ssh-ed25519 "*) echo "PASS three made the backup user's key: ${key:0:40}..." ;;
	*) echo "FAIL three did not make the backup user's key"; return 0 ;;
	esac
	if ! zero_make; then
		echo "FAIL could not make the runner's stand-in for zero's array"
		return 0
	fi
	if ! zero_up "$key"; then
		echo "FAIL could not set up zero's stand-in"
		sudo docker logs sim-zero 2>&1 | tail -n 10 | sed 's/^/    /'
		return 0
	fi
	echo "PASS zero's stand-in is set up as zero's README has the owner set up zero"
	zero_confined
	zero_postgres && pg_ok=yes
	zsnap

	echo "-- the first pull, over the LAN, with no rate limit"
	as_root three-backup.sh lan | sed 's/^/    /'
	n=$(znewest)
	as_root three-backup.sh pull "$n" 1
	as_root three-backup.sh first "$n"
	same_tree "$n"

	echo "-- a pull with nothing new"
	as_root three-backup.sh nothing-new 1

	echo "-- a second pull copies only what changed"
	before=$(as_root three-backup.sh ctime | tail -n 1)
	sudo bash -c "cd '$zimm/data/library' && echo three > c.jpg && rm b.jpg"
	zsnap
	n=$(znewest)
	as_root three-backup.sh pull "$n" 2
	as_root three-backup.sh changes "$before"
	same_tree "$n"

	echo "-- --delete never reaches three's own .snapshots"
	if sudo test -d "$zimm/.snapshots/$n/snapshot/.snapshots" &&
		[ -z "$(sudo ls -A "$zimm/.snapshots/$n/snapshot/.snapshots")" ]; then
		echo "PASS zero's snapshot holds an empty .snapshots, which --delete would mirror over three's"
	else
		echo "FAIL zero's snapshot holds no empty .snapshots placeholder, so the next checks prove less"
	fi
	as_root three-backup.sh delete-calibration

	echo "-- a pull cut off mid-way"
	sudo bash -c "head -c 24M /dev/urandom > '$zimm/data/library/big2.bin'"
	zsnap
	since=$(as_root three-backup.sh mark | tail -n 1)
	as_root three-backup.sh rate 256
	as_root three-backup.sh start
	if as_root three-backup.sh running data/library/big2.bin; then
		zero_caps
		zero_kill_daemon
	fi
	as_root three-backup.sh failed "$since" any 2
	as_root three-backup.sh rate default
	n=$(znewest)
	as_root three-backup.sh pull "$n" 3

	echo "-- files vanishing mid-pull: rsync's exit 24 is a failure"
	# A btrfs snapshot cannot lose a file, and snapper deleting one mid-pull does not either:
	# the first run deleted the snapshot being pulled and the pull finished, whole, because
	# the sender's working directory keeps the deleted subvolume readable to the end. So a
	# plain directory stands in for the newest snapshot, beside an info.xml, and loses three
	# files mid-pull. The slow file is in the last directory rsync reaches, with the files
	# after it, so the whole tree is listed first and they read as vanished (24), never as a
	# directory that could not be opened (23).
	n=$(znewest)
	n2=$((n + 1))
	sudo bash -c "set -e; s='$zimm/.snapshots'; mkdir \$s/$n2; cp \$s/$n/info.xml \$s/$n2/info.xml
		cp -a \$s/$n/snapshot \$s/$n2/snapshot; mkdir \$s/$n2/snapshot/zz
		head -c 24M /dev/urandom > \$s/$n2/snapshot/zz/big3.bin; for i in 1 2 3; do echo \$i > \$s/$n2/snapshot/zz/zzz-after-\$i; done" ||
		echo "FAIL could not make the stand-in snapshot $n2"
	since=$(as_root three-backup.sh mark | tail -n 1)
	as_root three-backup.sh rate 256
	as_root three-backup.sh start
	if as_root three-backup.sh running zz/big3.bin; then
		# Under sudo, glob and all: .snapshots is root's, so the runner's own shell would find
		# nothing to remove, and say nothing.
		if sudo sh -c "rm '$zimm/.snapshots/$n2/snapshot/zz/'zzz-after-* && ! ls '$zimm/.snapshots/$n2/snapshot/zz/' | grep -q after"; then
			echo "removed three files from the stand-in snapshot $n2 mid-pull"
		else
			echo "FAIL could not remove the files from the stand-in snapshot $n2"
		fi
	fi
	as_root three-backup.sh failed "$since" 24 3
	as_root three-backup.sh rate default
	sudo rm -rf "$zimm/.snapshots/$n2"
	zsnap
	n=$(znewest)
	as_root three-backup.sh pull "$n" 4

	echo "-- what three's key must not do on zero"
	as_root three-backup.sh confined

	echo "-- pruning, with small limits, on both sides"
	# zero: every snapshot dated a day apart at noon, the newest yesterday, limits of
	# hourly 1 and daily 2; then the hourly script, which takes one now and cleans up. It
	# must keep the one taken now and yesterday's.
	zx 'cp /etc/snapper/configs/immich /root/immich.tracked
		i=1; for n in $(ls /media/immich/.snapshots | sort -rn); do
			[ -e /media/immich/.snapshots/$n/info.xml ] || continue
			sed -i "s|<date>.*</date>|<date>$(date -u -d "@$(( $(date -u +%s) / 86400 * 86400 + 43200 - i * 86400 ))" "+%Y-%m-%d %H:%M:%S")</date>|" /media/immich/.snapshots/$n/info.xml
			i=$((i + 1))
		done
		snapper --no-dbus -c immich set-config TIMELINE_LIMIT_HOURLY=1 TIMELINE_LIMIT_DAILY=2'
	n=$(znewest)
	zsnap
	n2=$(znewest)
	zx 'snapper --no-dbus -c immich list' | sed 's/^/    /'
	if [ "$(sudo find "$zimm/.snapshots" -mindepth 2 -maxdepth 2 -name info.xml -printf '%h\n' | sed 's:.*/::' | sort -n | tr '\n' ' ')" = "$n $n2 " ]; then
		echo "PASS zero's cleanup, at hourly 1 and daily 2, kept the newest two: $n2, taken now, and $n"
	else
		echo "FAIL zero's cleanup kept the wrong snapshots"
	fi
	zx 'cp /root/immich.tracked /etc/snapper/configs/immich'
	as_root three-backup.sh pull "$n2" 5
	as_root three-backup.sh cleanup

	echo "-- against the locked array, then unlocked"
	printf '%s\n' "$password" | ssh_as gavin@127.0.0.1 \
		"sudo -S -p '' systemctl stop docker.service media-mirror.mount systemd-cryptsetup@mirror.service; and test ! -e /dev/mapper/mirror; and echo locked" ||
		echo "FAIL the README's lock command failed"
	as_root three-backup.sh locked
	sim_unlock || return 0
	as_root three-backup.sh unlocked
	zsnap
	n=$(znewest)
	as_root three-backup.sh pull "$n" 3

	echo "-- zero reads its own backups back, through the restore key"
	as_root three-backup.sh restore-user
	n2=$(as_root three-backup.sh newest | tail -n 1)
	zrs() { zx "rsync -e 'ssh -i /root/.ssh/restore -p $(cat port) -o StrictHostKeyChecking=accept-new -o BatchMode=yes' $*"; }
	# Less the placeholders of the nested subvolumes, whose times btrfs makes up at each
	# lookup; three-backup.sh's first step checked them. A symlink's owner is not kept (a
	# user xattr cannot be set on one), so the symlink may differ in owner and group alone;
	# its target, the third flag, may not.
	rc=0
	out=$(zrs "-naHAXc --numeric-ids -i --delete --exclude=/.snapshots --exclude=/data/thumbs --exclude=/data/encoded-video restore@127.0.0.1::backups/immich/current/.snapshots/$n2/snapshot/ /media/immich/.snapshots/$n/snapshot/" 2>&1) || rc=$?
	out=$(grep -v '^Warning: Permanently added' <<<"$out" || true)
	link='^\.L\.[^ ]{8} data/library/link\.jpg -> a\.jpg$'
	grep -qE "$link" <<<"$out" && echo "NOTE the symlink comes back with its target, and with the backup user's owner: $(grep -E "$link" <<<"$out")"
	if [ "$rc" = 0 ] && ! grep -vE "$link" <<<"$out" | grep -q .; then
		echo "PASS a checksum dry run through the restore module finds three's snapshot $n2 and zero's $n alike: contents, owners, modes, times, symlink targets"
	else
		echo "FAIL the restore module's copy differs from zero's snapshot $n (rsync exit $rc):"
		printf '%s\n' "$out" | head -n 12 | sed 's/^/    /'
	fi
	restore_dir=/root/restored
	zrs "--bwlimit=2000 -aHAX --numeric-ids --exclude=/.snapshots restore@127.0.0.1::backups/immich/current/.snapshots/$n2/snapshot/ $restore_dir/" > restore.log 2>&1 &
	as_root three-backup.sh caps restore
	wait $! && echo "zero restored three's snapshot $n2 into $restore_dir" || { echo "FAIL the restore failed:"; sed 's/^/    /' restore.log; }
	# Against zero's own snapshot, read the same way: Postgres's directory is 70:0 there, its
	# image's entrypoint giving the owner and not the group.
	out=$(zx "cd $restore_dir && stat -c '%n %u:%g %a' data/library/a.jpg db db/PG_VERSION; readlink data/library/link.jpg" 2>&1) || true
	want=$(zx "cd /media/immich/.snapshots/$n/snapshot && stat -c '%n %u:%g %a' data/library/a.jpg db db/PG_VERSION; readlink data/library/link.jpg" 2>&1) || true
	printf '%s\n' "$out" | sed 's/^/    restored: /'
	if [ -n "$out" ] && [ "$out" = "$want" ] && grep -q '^data/library/a.jpg 1000:1000 640$' <<<"$out" && [ "$(tail -n 1 <<<"$out")" = a.jpg ]; then
		echo "PASS the restore wrote zero's real owners and modes, and the symlink's own target"
	else
		echo "FAIL the restore did not put back owners, modes and the symlink as zero has them:"
		printf '%s\n' "$want" | sed 's/^/    zero: /'
	fi
	out=$(zx "ssh -i /root/.ssh/restore -p $(cat port) -o BatchMode=yes restore@127.0.0.1 'echo SIM-SHELL-OPENED' < /dev/null" 2>&1 || true)
	grep -q SIM-SHELL-OPENED <<<"$out" && echo "FAIL the restore key ran a command of its own" ||
		echo "PASS the restore key runs no command of its own"
	out=$(zrs "/etc/hostname restore@127.0.0.1::backups/sim-up" 2>&1 || true)
	grep -q 'read only' <<<"$out" && echo "PASS an upload through the restore key is refused, read only" ||
		echo "FAIL an upload through the restore key was not refused as read only: $(tail -n 1 <<<"$out")"
	zx 'rm -f /tmp/sim-shadow'
	zrs "restore@127.0.0.1::backups/../../../etc/shadow /tmp/sim-shadow" > /dev/null 2>&1 || true
	zx 'test ! -e /tmp/sim-shadow' && echo "PASS nothing outside the module is read through the restore key" ||
		echo "FAIL a file outside the module was read through the restore key"

	echo "-- a restore of the database in three's snapshot"
	if [ "$pg_ok" = yes ]; then
		as_root three-backup.sh restore-db "$n2" "$pg_image"
	else
		fail_or_skip "no restore: zero's Postgres did not run"
	fi

	sudo docker rm -f sim-pg sim-zero > /dev/null 2>&1 || true
	sudo umount "$zimm" "$ztop" || true
	[ -n "$zloop" ] && sudo losetup -d "$zloop" || true
}

sim_after_reboot() {
	echo "===== the array after the reboot, unlocked again"
	sim_unlock || return 0
	as_root three-unlocked.sh again
}
