# shellcheck shell=bash
# shellcheck disable=SC2034,SC2054  # read by run-host.sh; commas belong to qemu
# three's stand-ins for sim/microos/run-host.sh; sourced, never run.
#
# three is a NEW host, so its stick is the one `make-stick --new` builds: no tunnel
# credentials, .env, secrets or volumes (run-host.sh leaves them out for a host with no
# tunnel config). After the first boot, the hooks below do what the visit does next: put a
# tunnel in place as server-create-host-tunnel.yml and install-system-file would, format
# the drive with make-mirror, and unlock it with the README's own command. Then the runner
# stands in for zero and sends it the backup with zero's own mirror-backup.

# zero's two values in the backup user's authorized_keys, read from the tracked line and
# swapped on the stick for the run's own: its backup key, which the runner sends with as
# zero would, and the address the runner's connections arrive from, qemu's host address on
# this network. Everything else on the line is the tracked one, as the box will carry it.
rm -f backup-key backup-key.pub
ssh-keygen -q -t ed25519 -N '' -C 'sim zero mirror-backup' -f backup-key
zero_line=$(grep -v '^#' "$repo/hosts/three/leap/system/backup-authorized-keys")
zero_from=$(sed -n 's/.*from="\([^"]*\)".*/\1/p' <<<"$zero_line")
zero_key=$(grep -oE 'ssh-ed25519 [A-Za-z0-9+/=]+ .*$' <<<"$zero_line")
declare -A standin=(
	["$zero_key"]="$(cat backup-key.pub)"
	["$zero_from"]=192.168.86.1
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

# ── zero's backup, sent from the runner standing in for zero ─────────────────
# The runner plays zero with a small btrfs on a loop file, laid out as zero's array will be
# (plans/three-send-receive.md § The layout on zero): immich, holding data (thumbs and
# encoded-video nested subvolumes) and db, where a Postgres container writes throughout,
# and media-syncthing, with config nested. The runner's kernel and btrfs-progs differ from
# the Leap VM's, as zero's do from three's, so the send stream crosses a real gap. The
# script is the real hosts/zero/system/mirror-backup, run as root by BusyBox's shell with
# BusyBox's applets ahead of the runner's own, as on Alpine; only its MIRROR_BACKUP_*
# overrides point it at the loop file, the run's key and the VM. Postgres's image is a
# small stand-in for Immich's, the same on both sides.
pg_image=docker.io/library/postgres:16-alpine
ztop=$PWD/zero-top
zstate=$PWD/zero-state
zlast_minute=

# The applets Alpine takes from BusyBox, linked ahead of the runner's own. mount and umount
# stay util-linux's, which detach the loop device they set up.
zsh="sh"
zero_busybox() {
	local a have=()
	rm -rf bb && mkdir bb
	if ! command -v busybox > /dev/null; then
		fail_or_skip "no busybox on the runner; mirror-backup runs under the runner's own sh and tools"
		return 0
	fi
	zsh="busybox sh"
	busybox --list > bb.list
	for a in awk cat chmod date flock grep head install ls mkdir mountpoint mv sed sort tail tr wc; do
		if grep -qx "$a" bb.list; then
			ln -s "$(command -v busybox)" "bb/$a"
			have+=("$a")
		fi
	done
	echo "BusyBox stands in for: ${have[*]}"
}
# shellcheck disable=SC2086  # zsh is one word or two, on purpose
zero_mb() {
	sudo env PATH="$PWD/bb:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
		MIRROR_BACKUP_THREE=127.0.0.1 MIRROR_BACKUP_PORT="$(cat port)" \
		MIRROR_BACKUP_KEY="$PWD/backup-key" MIRROR_BACKUP_STATE="$zstate" MIRROR_BACKUP_TOP="$ztop" \
		$zsh "$repo/hosts/zero/system/mirror-backup" now "$@"
}
# One run, its log kept as <log> and shown. A stamp names a minute, so each run waits for a
# minute no earlier run ended in.
zero_wait_minute() {
	while [ "$(date -u +%Y%m%d%H%M)" = "$zlast_minute" ]; do sleep 1; done
}
zero_run() {
	local log=$1 rc=0
	shift
	zero_wait_minute
	zero_mb "$@" || rc=$?
	zlast_minute=$(date -u +%Y%m%d%H%M)
	# shellcheck disable=SC2024  # the copy is the runner's, readable for the checks
	sudo cat "$zstate/last.log" > "$log" 2> /dev/null || true
	sed 's/^/    | /' "$log"
	return "$rc"
}
zsent() { sudo cat "$zstate/last-sent-$1" 2> /dev/null || echo none; }
zsuccess() { sudo cat "$zstate/last-success" 2> /dev/null || echo none; }
zuuid() {
	local u
	u=$(sudo btrfs subvolume show "$ztop/snapshots/$1/$2" 2> /dev/null | awk '$1 == "UUID:" { print $2; exit }') || true
	echo "${u:-none}"
}
zcount() { { sudo find "$ztop/snapshots/$1" -mindepth 1 -maxdepth 1 2> /dev/null || true; } | wc -l; }
tcount() { { as_root three-backup.sh n "$1" 2> /dev/null || true; } | tail -n 1; }
# The same snapshot on both sides, by tree-hash.sh.
same_tree() {
	local a b
	a=$(sudo bash "$here/host/tree-hash.sh" "$ztop/snapshots/$1/$2" 2>&1 | tail -n 1) || true
	b=$(as_root tree-hash.sh "/media/mirror/received-backups/$1/$2" 2>&1 | tail -n 1) || true
	if [ -n "$a" ] && [ "$a" = "$b" ]; then
		echo "PASS $2 is the same tree on both sides: every path, owner, mode, size and content"
	else
		echo "FAIL $2 differs: the runner's hashes to ${a:-nothing}, three's to ${b:-nothing}"
	fi
}
# The backup key, as zero's script uses it, for the calls zero's script never makes.
bk() {
	ssh -i backup-key -p "$(cat port)" -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=no \
		-o UserKnownHostsFile=known backup@127.0.0.1 "$@"
}
fail_or_skip() {
	if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "FAIL $*"; else echo "SKIP $*"; fi
}

# zero's array in miniature, unmounted at the end, as zero's /mnt/ext is between runs. Its
# fstab entry is noauto, as zero's is, so `mount <top>` is what the script runs.
# Called in an || list, where set -e does not reach, so each step checks its own result.
zero_make() {
	sudo umount "$ztop" 2> /dev/null || true
	rm -f zero.img && truncate -s 2G zero.img && mkfs.btrfs -q -L zero-sim zero.img && mkdir -p "$ztop" || return 1
	sudo sed -i "\\|[[:space:]]${ztop}[[:space:]]|d" /etc/fstab || return 1
	echo "$PWD/zero.img $ztop btrfs noauto,loop 0 0" | sudo tee -a /etc/fstab > /dev/null || return 1
	sudo mount "$ztop" || return 1
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
head -c 8M /dev/urandom > "$t/immich/data/library/big.bin"
echo dump > "$t/immich/data/backups/immich-db-backup.sql.gz"
btrfs subvolume create "$t/media-syncthing" > /dev/null
mkdir -p "$t/media-syncthing/share"
echo kept > "$t/media-syncthing/share/kept.txt"
echo gone > "$t/media-syncthing/share/gone.txt"
head -c 8M /dev/urandom > "$t/media-syncthing/share/big.bin"
btrfs subvolume create "$t/media-syncthing/config" > /dev/null
echo "zero's device key" > "$t/media-syncthing/config/key.pem"
chown -R 1000:1000 "$t/media-syncthing/share" "$t/media-syncthing/config"
MAKE
	sudo btrfs subvolume list "$ztop" | sed 's/^/    /'
	sudo umount "$ztop"
}

# A Postgres on immich/db: 100 rows, then a writer that never stops, so every snapshot from
# here on catches it mid-write, as zero's snapshots catch Immich's.
zero_postgres() {
	local i l
	if ! command -v docker > /dev/null; then
		fail_or_skip "no docker on the runner for the Postgres that writes during the snapshot"
		return 1
	fi
	sudo docker rm -f sim-pg > /dev/null 2>&1 || true
	sudo docker pull -q "$pg_image" > /dev/null || true
	if ! sudo docker run -d --name sim-pg -e POSTGRES_PASSWORD=sim \
		-v "$ztop/immich/db:/var/lib/postgresql/data" "$pg_image" > /dev/null; then
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
		echo "Postgres on the runner's immich/db holds 100 rows, and a writer adds more throughout"
	else
		echo "FAIL could not write the rows into the runner's Postgres:"
		sudo docker logs sim-pg 2>&1 | tail -n 10 | sed 's/^/    /'
		return 1
	fi
}

sim_backup() {
	local rc i pg_ok=no snap_i snap_s prev_i prev_s n_i n_s before bg pids out c half stamp s uuid
	local full_i inc_i full_s inc_s
	echo "===== zero's backup, sent by hosts/zero/system/mirror-backup from the runner standing in for zero"
	zero_busybox
	if ! zero_make; then
		echo "FAIL could not make the runner's stand-in for zero's array"
		return 0
	fi
	sudo rm -rf "$zstate"
	as_root three-backup.sh layout

	echo "-- no full send unasked"
	rc=0
	zero_run zero-unasked.log || rc=$?
	if [ "$rc" != 0 ] && grep -q 'immich has no parent to send from' zero-unasked.log &&
		grep -q 'syncthing has no parent to send from' zero-unasked.log &&
		[ "$(zsuccess)" = none ]; then
		echo "PASS with no last-sent and no full, the run refuses both subvolumes and writes no success"
	else
		echo "FAIL the run with no last-sent did not refuse as it should (exit $rc)"
	fi
	# It could only say there was no parent once it had mounted the top level to look.
	if ! mountpoint -q "$ztop"; then
		echo "PASS the run mounted the array's top level itself, and unmounted it after"
	else
		echo "FAIL the run left the array's top level mounted, though it found it unmounted"
	fi
	sudo mount "$ztop"
	if [ "$(zcount immich)" = 0 ] && [ "$(zcount syncthing)" = 0 ]; then
		echo "PASS it took no snapshot"
	else
		echo "FAIL it left a snapshot behind: $(sudo ls "$ztop/snapshots/immich" "$ztop/snapshots/syncthing" | tr '\n' ' ')"
	fi
	as_root three-backup.sh layout
	zero_postgres && pg_ok=yes

	echo "-- a full send"
	rc=0
	zero_run zero-full.log full || rc=$?
	snap_i=$(zsent immich) snap_s=$(zsent syncthing)
	if [ "$rc" = 0 ] && [ "$snap_i" != none ] && [ "$snap_s" != none ] && [ "$(zsuccess)" != none ] &&
		grep -q "three answered: received $snap_i $(zuuid immich "$snap_i") " zero-full.log &&
		grep -q "three answered: received $snap_s $(zuuid syncthing "$snap_s") " zero-full.log; then
		echo "PASS both went in full, three confirmed each by its UUID, and last-success is written"
	else
		echo "FAIL the full send (exit $rc)"
	fi
	if mountpoint -q "$ztop"; then
		echo "PASS the run left the top level mounted, as it found it"
	else
		echo "FAIL the run unmounted a top level it had not mounted"
	fi
	as_root three-backup.sh received immich "$snap_i" "$(zuuid immich "$snap_i")"
	as_root three-backup.sh received syncthing "$snap_s" "$(zuuid syncthing "$snap_s")"
	as_root three-backup.sh nested "$snap_i" "$snap_s"
	same_tree immich "$snap_i"
	same_tree syncthing "$snap_s"

	echo "-- an incremental"
	prev_i=$snap_i prev_s=$snap_s
	sudo bash -c "cd '$ztop' && echo added > immich/data/library/added.jpg && rm immich/data/library/b.jpg &&
		echo added > media-syncthing/share/added.txt && rm media-syncthing/share/gone.txt"
	rc=0
	zero_run zero-incremental.log || rc=$?
	snap_i=$(zsent immich) snap_s=$(zsent syncthing)
	if [ "$rc" = 0 ] && grep -q "incremental from $prev_i\$" zero-incremental.log &&
		grep -q "incremental from $prev_s\$" zero-incremental.log; then
		echo "PASS both went as incrementals, from the snapshots sent before"
	else
		echo "FAIL the incremental send (exit $rc)"
	fi
	as_root three-backup.sh received immich "$snap_i" "$(zuuid immich "$snap_i")"
	as_root three-backup.sh received syncthing "$snap_s" "$(zuuid syncthing "$snap_s")"
	as_root three-backup.sh incremental "$snap_i" "$snap_s"
	same_tree immich "$snap_i"
	same_tree syncthing "$snap_s"
	full_s=$(sudo btrfs send -q "$ztop/snapshots/syncthing/$prev_s" | wc -c) || true
	inc_s=$(sudo btrfs send -q -p "$ztop/snapshots/syncthing/$prev_s" "$ztop/snapshots/syncthing/$snap_s" | wc -c) || true
	full_i=$(sudo btrfs send -q "$ztop/snapshots/immich/$prev_i" | wc -c) || true
	inc_i=$(sudo btrfs send -q -p "$ztop/snapshots/immich/$prev_i" "$ztop/snapshots/immich/$snap_i" | wc -c) || true
	if [ "${inc_s:-0}" -gt 0 ] && [ $((inc_s * 100)) -lt "${full_s:-0}" ]; then
		echo "PASS syncthing's incremental stream is $inc_s bytes, against $full_s in full"
	else
		echo "FAIL syncthing's incremental stream is ${inc_s:-?} bytes, against ${full_s:-?} in full"
	fi
	echo "NOTE immich's incremental stream is ${inc_i:-?} bytes, against ${full_i:-?} in full, with Postgres's writes"

	echo "-- what the key must not do"
	for c in 'echo SIM-SHELL-OPENED; touch /tmp/sim-escape-shell' 'immich; touch /tmp/sim-escape-chain' \
		'immich syncthing' 'immich ' other media-syncthing '../../../tmp/sim-escape-dots' ''; do
		out=$(bk "$c" < /dev/null 2>&1 || true)
		if grep -q SIM-SHELL-OPENED <<<"$out"; then
			echo "FAIL the key ran a command of its own: '$c'"
		elif grep -q 'mirror-receive: refused' <<<"$out"; then
			echo "PASS the forced command refuses '$c'"
		else
			echo "FAIL '$c' was refused, but not by the forced command: $(tail -n 1 <<<"$out")"
		fi
	done
	out=$(bk immich < /dev/null 2> bk-empty.err || true)
	if [ -z "$out" ] && grep -q 'mirror-receive' bk-empty.err; then
		echo "PASS an empty stream is refused, with nothing back on stdout: $(tail -n 1 bk-empty.err)"
	else
		echo "FAIL an empty stream: stdout '$out', stderr $(tail -n 1 bk-empty.err)"
	fi
	out=$(head -c 1048576 /dev/urandom | bk immich 2> bk-junk.err || true)
	if [ -z "$out" ] && grep -q 'mirror-receive' bk-junk.err; then
		echo "PASS a stream that is not btrfs's is refused, with nothing back: $(tail -n 1 bk-junk.err)"
	else
		echo "FAIL a junk stream: stdout '$out', stderr $(tail -n 1 bk-junk.err)"
	fi
	rm -f pulled
	echo 'get /etc/passwd pulled' | sftp -i backup-key -P "$(cat port)" -o IdentitiesOnly=yes -o BatchMode=yes \
		-o StrictHostKeyChecking=no -o UserKnownHostsFile=known -b - backup@127.0.0.1 > sftp.log 2>&1 || true
	if [ ! -e pulled ]; then
		echo "PASS sftp reads nothing back: $(tail -n 1 sftp.log)"
	else
		echo "FAIL sftp read a file back through the key"
	fi
	# Forwarding is asked for only when a connection comes through, so one is made, to
	# three's own sshd at an address PermitOpen allows; gavin's key, which may forward
	# there, shows the test can see a forward that works.
	local who k banner fpid
	for who in gavin backup; do
		k=key
		[ "$who" = backup ] && k=backup-key
		ssh -i "$k" -p "$(cat port)" -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=no \
			-o UserKnownHostsFile=known -N -L 127.0.0.1:2299:192.168.86.103:22 "$who@127.0.0.1" > fwd.log 2>&1 &
		fpid=$!
		sleep 5
		banner=$(timeout 10 bash -c 'exec 3<>/dev/tcp/127.0.0.1/2299; head -c 7 <&3' 2> /dev/null || true)
		kill "$fpid" 2> /dev/null || true
		wait "$fpid" 2> /dev/null || true
		case "$who:$banner" in
		gavin:SSH-2.0) echo "PASS a forward that is allowed is seen, through gavin's key" ;;
		gavin:*) echo "FAIL the forwarding test cannot see even gavin's allowed forward: $(tail -n 1 fwd.log)" ;;
		backup:SSH-2.0) echo "FAIL the backup key forwarded a connection" ;;
		backup:*) echo "PASS the backup key forwards nothing: $(grep -m1 -i 'open failed\|prohibited' fwd.log || echo refused)" ;;
		esac
	done
	as_root three-backup.sh confined 2 2

	echo "-- against the locked array, then unlocked"
	printf '%s\n' "$password" | ssh_as gavin@127.0.0.1 \
		"sudo -S -p '' systemctl stop docker.service media-mirror.mount systemd-cryptsetup@mirror.service; and test ! -e /dev/mapper/mirror; and echo locked" ||
		echo "FAIL the README's lock command failed"
	as_root three-backup.sh locked
	prev_i=$(zsent immich) prev_s=$(zsent syncthing) n_i=$(zcount immich) n_s=$(zcount syncthing) before=$(zsuccess)
	rc=0
	zero_run zero-locked.log || rc=$?
	if [ "$rc" != 0 ] && grep -q 'is not mounted: the array is locked' zero-locked.log &&
		[ "$(zsent immich)" = "$prev_i" ] && [ "$(zsent syncthing)" = "$prev_s" ] &&
		[ "$(zcount immich)" = "$n_i" ] && [ "$(zcount syncthing)" = "$n_s" ] && [ "$(zsuccess)" = "$before" ]; then
		echo "PASS a run against the locked array fails cleanly: three says why, the runner deleted both new snapshots and kept each parent, and wrote no success"
	else
		echo "FAIL the run against the locked array (exit $rc)"
	fi
	sim_unlock || return 0
	rc=0
	zero_run zero-unlocked.log || rc=$?
	if [ "$rc" = 0 ] && grep -q "incremental from $prev_i\$" zero-unlocked.log &&
		grep -q "incremental from $prev_s\$" zero-unlocked.log && [ "$(zsuccess)" != "$before" ]; then
		echo "PASS the next run, once unlocked, succeeds from the same parents"
	else
		echo "FAIL the run after the unlock (exit $rc)"
	fi
	as_root three-backup.sh count immich 3
	as_root three-backup.sh count syncthing 3

	echo "-- an interrupted send"
	prev_i=$(zsent immich) n_i=$(zcount immich) before=$(zsuccess)
	sudo bash -c "head -c 24M /dev/urandom > '$ztop/immich/data/library/big2.bin'"
	echo 512K | sudo tee "$zstate/rate" > /dev/null
	zero_wait_minute
	zero_mb > /dev/null 2>&1 &
	bg=$!
	# The receive must be under way on three before the cut, or the cut proves nothing.
	half=no
	for i in $(seq 1 40); do
		if as_root three-backup.sh has-half immich > half.log 2>&1; then
			half=yes
			break
		fi
		sleep 1
	done
	pids=$(pgrep -u root -x ssh || true)
	if [ -n "$pids" ]; then
		# shellcheck disable=SC2086  # a list of pids
		sudo kill $pids || true
	fi
	wait "$bg" || true
	zlast_minute=$(date -u +%Y%m%d%H%M)
	sudo rm -f "$zstate/rate"
	# shellcheck disable=SC2024  # the copy is the runner's
	sudo cat "$zstate/last.log" > zero-cut.log 2> /dev/null || true
	sed 's/^/    | /' zero-cut.log
	if [ "$half" = yes ] && [ -n "$pids" ]; then
		echo "PASS the runner's ssh was killed with immich's receive under way on three:"
		sed 's/^/    /' half.log
	else
		echo "FAIL the cut did not land mid-stream (receive under way: $half; ssh pids: ${pids:-none})"
	fi
	if grep -q 'three did not confirm immich-' zero-cut.log && [ "$(zsent immich)" = "$prev_i" ] &&
		sudo test -d "$ztop/snapshots/immich/$prev_i" && [ "$(zcount immich)" = "$n_i" ] &&
		[ "$(zsuccess)" = "$before" ]; then
		echo "PASS the runner deleted its new immich snapshot, kept the parent $prev_i, and wrote no success"
	else
		echo "FAIL the cut send left the runner in the wrong state"
	fi
	if as_root three-backup.sh has-half immich > /dev/null 2>&1; then
		echo "NOTE the cut stream's half is still on three, for the next receive to delete"
	else
		echo "NOTE mirror-receive deleted the cut stream's half itself, as the stream ended"
	fi
	as_root three-backup.sh plant immich
	rc=0
	zero_run zero-after-cut.log || rc=$?
	snap_i=$(zsent immich)
	if [ "$rc" = 0 ] && grep -q "incremental from $prev_i\$" zero-after-cut.log; then
		echo "PASS the next run succeeds, still from $prev_i"
	else
		echo "FAIL the run after the cut (exit $rc)"
	fi
	as_root three-backup.sh clean immich "$snap_i"
	same_tree immich "$snap_i"

	echo "-- a restore of the received database"
	if [ "$pg_ok" = yes ]; then
		as_root three-backup.sh restore "$snap_i" "$pg_image"
	else
		fail_or_skip "no restore: the runner's Postgres did not run"
	fi

	echo "-- pruning, with 0 days kept"
	# mirror-receive keeps 90 days, and zero cannot change it; gavin's sudo can, so the
	# stream goes in through gavin, with MIRROR_RECEIVE_KEEP_DAYS=0, which every snapshot
	# but the one received is older than.
	n_s=$(tcount syncthing)
	prev_i=$(zsent immich)
	zero_wait_minute
	stamp=$(date -u +%Y-%m-%dT%H%MZ)
	zlast_minute=$(date -u +%Y%m%d%H%M)
	s=immich-$stamp
	sudo btrfs subvolume snapshot -r "$ztop/immich" "$ztop/snapshots/immich/$s" > /dev/null ||
		echo "FAIL could not take $s on the runner"
	uuid=$(zuuid immich "$s")
	out=$({ printf '%s\n' "$password"; sudo btrfs send -q -p "$ztop/snapshots/immich/$prev_i" "$ztop/snapshots/immich/$s"; } |
		ssh_as gavin@127.0.0.1 "sudo -S -p '' env MIRROR_RECEIVE_KEEP_DAYS=0 /usr/local/sbin/mirror-receive immich" \
		2> prune.err || true)
	if [ "$out" = "received $s $uuid" ]; then
		echo "PASS mirror-receive, with 0 days kept, received $s"
	else
		echo "FAIL the receive with 0 days kept answered '$out': $(tail -n 3 prune.err | tr '\n' ' ')"
	fi
	sed 's/^/    /' prune.err
	as_root three-backup.sh pruned immich "$s" syncthing "$n_s"
	echo "$s" | sudo tee "$zstate/last-sent-immich" > /dev/null
	rc=0
	zero_run zero-after-prune.log || rc=$?
	if [ "$rc" = 0 ] && grep -q "incremental from $s\$" zero-after-prune.log; then
		echo "PASS the next run sends from the one snapshot three kept"
	else
		echo "FAIL the run after the pruning (exit $rc)"
	fi

	sudo docker rm -f sim-pg > /dev/null 2>&1 || true
	sudo umount "$ztop" || true
}

sim_after_reboot() {
	echo "===== the array after the reboot, unlocked again"
	sim_unlock || return 0
	as_root three-unlocked.sh again
}
