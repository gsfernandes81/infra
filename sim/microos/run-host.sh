#!/bin/bash
# Boots a host's real first-boot script (hosts/<host>/leap/combustion/script) in a Leap 16.1
# Immutable VM, from a stick laid out as leap/make-stick lays it out but filled with
# stand-ins, then checks the box it makes: its ways in, its users and sudo, its disks and
# Docker, its pinned binaries, and rescue mode. CI runs it (.github/workflows/microos-sim.yml).
#
# Usage: sim/microos/run-host.sh <workdir> <host>
# It writes only inside <workdir>, except one loop mount under sudo to make the stand-in
# SSD's subvolumes. Every check prints PASS or FAIL; any FAIL fails the run.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
work=${1:?usage: run-host.sh <workdir> <host>}
host=${2:?usage: run-host.sh <workdir> <host>}
mkdir -p "$work"
cd "$work"

# shellcheck source=sim/microos/lib.sh
. "$here/lib.sh"
# shellcheck source=sim/microos/host/one.sh
. "$here/host/$host.sh"
# A host with no tunnel config yet is new: its stick is make-stick --new's, which carries
# no tunnel credentials, .env, secrets directory or volume (leap/README.md).
new_host=no
[ -e "$repo/hosts/$host/leap/system/cloudflared-config.yml" ] || new_host=yes

report() { tee -a report.txt; }
: > report.txt

fetch_image | report

# ── the stick, as make-stick lays it out ─────────────────────────────────────
# The host's files are copied as they are, then each FILL-FROM- placeholder is replaced by
# the stand-in host/<host>.sh gives it. A placeholder with no stand-in stops the run, so a
# new one cannot slip through untested.
rm -rf stick key key.pub && mkdir -p stick/combustion/carry
ssh-keygen -q -t ed25519 -N '' -f key
s=stick/combustion
install -D -m 755 "$repo/hosts/$host/leap/combustion/script" "$s/script"
install -D -m 644 "$repo/leap/firstboot.sh" "$s/leap/firstboot.sh"
install -D -m 644 "$repo/leap/tailscale-repo.gpg" "$s/leap/tailscale-repo.gpg"
install -D -m 644 "$repo/hosts/$host/leap/fstab.append" "$s/host/fstab.append"
mkdir -p "$s/host/system" && cp -p "$repo/hosts/$host/leap/system/"* "$s/host/system/"
for token in "${!standin[@]}"; do
	# Not every placeholder is on the stick (a host's volumes list is read by make-stick).
	{ grep -rl -- "$token" stick || true; } | xargs -r sed -i "s|$token|${standin[$token]}|g"
done
if grep -rn 'FILL-FROM-' stick; then
	echo "FAIL a placeholder above has no stand-in in sim/microos/host/$host.sh" | report
	exit 1
fi
echo "stand-ins used: ${!standin[*]}" | report

# The carry-over, made up for this run.
password=$(openssl rand -hex 12)
c=$s/carry
mkdir -p "$c/ssh" "$c/shadow" "$c/gavin" "$c/cloudflared" "$c/env" "$c/volumes"
ssh-keygen -q -t ed25519 -N '' -C "sim $host" -f "$c/ssh/ssh_host_ed25519_key"
root_password=$(openssl rand -hex 12)
openssl passwd -6 "$root_password" > "$c/shadow/root"
openssl passwd -6 "$password" > "$c/shadow/gavin"
cp key.pub "$c/gavin/authorized_keys"
[ "$new_host" = yes ] || printf '{"AccountTag":"sim","TunnelSecret":"c2lt","TunnelID":"%s"}\n' \
	"$tunnel_id" > "$c/cloudflared/$host.json"
for dep in "${deployments[@]}"; do
	[ "$new_host" = no ] || break
	# Every name compose.yaml requires (`${NAME:?}`), as the deploy play checks, each with
	# the stand-in host/<host>.sh gives it.
	# The same pattern as the play's own check (_deploy-compose-one.yml).
	for name in $(grep -oE '\$\{[A-Za-z0-9_]+:\?' "$repo/deployments/$dep/compose.yaml" | tr -d '${:?' | sort -u); do
		printf '%s=%s\n' "$name" "$(standin_env "$dep" "$name")"
	done > "$c/env/$dep.env"
	printf 'SIM_STANDIN=1\n' >> "$c/env/$dep.env"
	mkdir -p "$c/home/.$dep-secrets"
	printf '{}\n' > "$c/home/.$dep-secrets/tunnel.json"
done
for vol in "${volumes[@]}"; do
	mkdir -p "vol-$vol" && echo "$vol" > "vol-$vol/marker"
	tar -C "vol-$vol" -cf "$c/volumes/$vol.tar" .
done
mke2fs -q -t ext4 -L combustion -d stick combustion.img 64M

# ── the host's disks ─────────────────────────────────────────────────────────
make_disks | report

# ── boot ─────────────────────────────────────────────────────────────────────
# The guest must answer on its static address, from the first boot on: the host's script
# installs its profile in Combustion's prepare stage, so even the initramfs's network uses
# it. The first address qemu's DHCP hands out is tried as well, so a box that missed its
# profile is still reached and examined, and reported as a FAIL. The port that answered is
# kept in a file, because the functions below run inside pipelines.
static_port=$ssh_port
dhcp_port=$((ssh_port + 1))
ssh_as() {
	ssh -q -i key -p "$(cat port 2>/dev/null || echo "$static_port")" \
		-o StrictHostKeyChecking=no -o UserKnownHostsFile=known \
		-o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 \
		-o BatchMode=yes "$@"
}
# Answers once gavin can log in with the run's key. `wait_gavin static` accepts only the
# static address.
wait_gavin() {
	local i p ports=("$static_port" "$dhcp_port")
	[ "${1:-}" = static ] && ports=("$static_port")
	for i in $(seq 1 120); do
		for p in "${ports[@]}"; do
			echo "$p" > port
			if ssh_as gavin@127.0.0.1 true 2>/dev/null; then
				if [ "$p" = "$static_port" ]; then
					echo "gavin's ssh up after ~$((i * 5))s, on $sim_address"
				else
					echo "FAIL gavin's ssh answered on the DHCP address only, not $sim_address"
				fi
				return 0
			fi
		done
		sleep 5
	done
	echo "FAIL gavin cannot log in after 10 minutes; the console says why:"
	python3 -I "$here/serial-login.py" serial.sock "$root_password" "$(cat <<'DIAG'
systemctl --no-pager --failed; systemctl --no-pager status sshd | head -n 20
journalctl -b --no-pager -u sshd | tail -n 30
getent passwd gavin; ls -laZ /home/gavin /home/gavin/.ssh; findmnt /home
sshd -T 2>&1 | grep -iE '^(authorizedkeysfile|permitrootlogin|passwordauthentication|allowusers|usepam) '
ausearch --input-logs -m avc -ts boot < /dev/null 2>&1 | tail -n 20
ip -br addr; nmcli -f NAME,DEVICE,FILENAME connection show
journalctl -b --no-pager -u combustion | tail -n 40
DIAG
)" "journalctl --no-pager -b | grep -iE 'combustion|prepare|NetworkManager|nm-initrd' | tail -n 60" ||
		tail -n 80 serial.log
	return 1
}
# Runs a script on the guest as root through gavin's sudo, which reads his password first,
# with any arguments after its name. host/<script>-<host>.sh, if there is one, is appended
# to it: checks.sh's host part, checks-one.sh or checks-three.sh.
as_root() {
	local script=$1 extra=$here/host/${1%.sh}-$host.sh
	shift
	cat "$here/host/$script" "$([ -e "$extra" ] && echo "$extra" || echo /dev/null)" |
		ssh_as gavin@127.0.0.1 "cat > /tmp/sim-$script"
	printf '%s\n' "$password" | ssh_as gavin@127.0.0.1 \
		"sudo -S -p '' env EXPECT_UID=$expect_uid EXPECT_GID=$expect_gid EXPECT_CLOUDFLARED=$expect_cloudflared EXPECT_NEW_HOST=$new_host bash /tmp/sim-$script $*"
}

# What checks.sh compares against, read from the files the box was made from.
expect_uid=$(sed -n 's/^gavin_uid=//p' "$repo/hosts/$host/leap/combustion/script")
expect_gid=$(sed -n 's/^gavin_gid=//p' "$repo/hosts/$host/leap/combustion/script")
expect_cloudflared=$(sed -n 's/^cloudflared_version=//p' "$repo/leap/firstboot.sh")

rm -f known
sim_netdev="user,id=n0,net=$sim_net,host=$sim_gateway,dns=$sim_dns"
sim_netdev+=",hostfwd=tcp:127.0.0.1:$static_port-$sim_address:22"
sim_netdev+=",hostfwd=tcp:127.0.0.1:$dhcp_port-$sim_dhcp_address:22"
sim_serial_socket=$PWD/serial.sock
boot_vm "${disk_args[@]}"
wait_gavin | report

# ── what only the runner can see ─────────────────────────────────────────────
{
	echo "===== from outside"
	want=$(awk '{print $2}' "$c/ssh/ssh_host_ed25519_key.pub")
	have=$(ssh-keyscan -t ed25519 -p "$(cat port)" 127.0.0.1 2>/dev/null | awk '{print $3}')
	[ "$want" = "$have" ] && echo "PASS the host key is the carried one" \
		|| echo "FAIL the host key is not the carried one"
	# Not through ssh_as: its -q hides the refusal this reads.
	if ssh -i key -p "$(cat port)" -o StrictHostKeyChecking=no -o UserKnownHostsFile=known \
		-o BatchMode=yes -o PubkeyAuthentication=no gavin@127.0.0.1 true 2> pw.err; then
		echo "FAIL a login without a key got in"
	elif grep -q 'Permission denied (publickey)' pw.err; then
		echo "PASS sshd offers publickey only"
	else
		echo "FAIL sshd's refusal was not publickey-only: $(cat pw.err)"
	fi
	# A valid key in root's authorized_keys, which the box never has, must still be refused.
	{ printf '%s\n' "$password"; cat key.pub; } |
		ssh_as gavin@127.0.0.1 "sudo -S -p '' sh -c 'install -d -m 700 /root/.ssh; cat > /root/.ssh/authorized_keys'"
	if ssh_as root@127.0.0.1 true 2>/dev/null; then
		echo "FAIL root logged in over ssh with a valid key"
	elif printf '%s\n' "$password" | ssh_as gavin@127.0.0.1 \
		"sudo -S -p '' journalctl -b --no-pager -u sshd" | grep -q 'ROOT LOGIN REFUSED'; then
		echo "PASS root is refused over ssh with a valid key in place, by PermitRootLogin"
	else
		echo "FAIL root was refused, but not by PermitRootLogin: the key may not have been read"
	fi
	# The console takes root's password: the way in when nothing else is left.
	if python3 -I "$here/serial-login.py" serial.sock "$root_password" true >/dev/null; then
		echo "PASS root logs in on the serial console with its password"
	else
		echo "FAIL root cannot log in on the serial console"
	fi
	printf '%s\n' "$password" | ssh_as gavin@127.0.0.1 "sudo -S -p '' rm -f /root/.ssh/authorized_keys"
} 2>&1 | report

{ echo "===== first boot"; as_root checks.sh; } 2>&1 | report

# What the visit does next on this host, if host/<host>.sh says: on three, its tunnel and
# its array.
if declare -F sim_after_firstboot >/dev/null; then
	sim_after_firstboot 2>&1 | report
fi

# ── the deploy play plans each deployment ────────────────────────────────────
# server-deploy-compose.yml, run from the runner as the control node, in --check: for each
# of the host's deployments it pulls and checks the host's checkout, reads Compose's
# version, runs the preflight hook, checks .env, reads the one-shots, asks the registries
# for every image and has Compose plan `up`. Only --check, because a real `up` needs what a
# stand-in cannot give: each cloudflared sidecar is healthy only once its tunnel connects.
# Needs ansible-playbook and the collections in ansible/requirements.yml; without them the
# section says so and is skipped.
deploy_plans() {
	local sha guest dep rc line
	local inv=$repo/ansible/inventory.sim-host vars=$PWD/become.yml
	# Removed however the stage ends: the vars file holds the sudo password, and a stale
	# inventory in ansible/ would be read by the next local run.
	trap 'rm -f "$inv" "$vars"' EXIT
	echo "===== the deploy play, --check, for each of $host's deployments"
	if ! command -v ansible-playbook >/dev/null; then
		skip "no ansible-playbook here"
		return 0
	fi
	# The box's checkout must be on exactly the commit this run tests, as the play requires
	# of a host. It is fetched by its sha, or for a pull request by the ref GitHub tests,
	# whose merge commit is on no branch, onto a local branch that tracks itself, so the
	# play's own `git pull --ff-only` has an upstream and finds nothing newer: a branch that
	# moved on since this run was queued cannot pull the box past the commit under test.
	sha=$(git -C "$repo" rev-parse HEAD)
	# gavin's login shell is fish, so each step on the box goes to bash on stdin, and a
	# failed one is printed rather than ending the run under set -e.
	guest=$(ssh_as gavin@127.0.0.1 bash -s <<STEP 2>&1 || true
set -e
cd ~/infra
git fetch -q origin '$sha' 2>/dev/null || git fetch -q origin '${GITHUB_REF:-refs/heads/main}'
git checkout -q -B sim-under-test FETCH_HEAD
git config branch.sim-under-test.remote .
git config branch.sim-under-test.merge refs/heads/sim-under-test
git rev-parse HEAD
STEP
)
	if [ "$(printf '%s\n' "$guest" | tail -n 1)" != "$sha" ]; then
		skip "the box cannot be put on the commit under test, $sha:"
		printf '%s\n' "$guest" | sed 's/^/    /'
		return 0
	fi
	if declare -F sim_before_deploy >/dev/null; then sim_before_deploy; fi
	# The images first, as a deploy's own pull would leave them, so the plan reaches
	# Compose's dry run: the play stops short of it while any image is missing. A pull that
	# fails is noted, not failed (an arm64-only image cannot be pulled on this x86 VM), and
	# built images are left out, as the play leaves them to `up`.
	for dep in "${deployments[@]}"; do
		if printf '%s\n' "$password" | ssh_as gavin@127.0.0.1 \
			"sudo -S -p '' docker compose --project-directory ~/infra/deployments/$dep pull --quiet --ignore-buildable" \
			> "pull-$dep.log" 2>&1; then
			echo "pulled $dep's images"
		else
			echo "NOTE could not pull every image of $dep; its plan stops before the dry run:"
			tail -n 5 "pull-$dep.log" | sed 's/^/    /'
		fi
	done
	# Each carried volume restored as leap/README.md § the named volumes says, before any
	# deploy, then read back through a container. The stand-in tar holds a marker naming it.
	for vol in "${volumes[@]}"; do
		if { printf '%s\n' "$password"; cat <<RESTORE; } | ssh_as gavin@127.0.0.1 "sudo -S -p '' bash -s" > "restore-$vol.log" 2>&1; then
set -e
docker volume create --label com.docker.compose.project=${vol%%_*} --label com.docker.compose.volume=${vol#*_} $vol >/dev/null
tar --numeric-owner -C "\$(docker volume inspect -f '{{.Mountpoint}}' $vol)" -xpf /root/volumes/$vol.tar
docker volume inspect -f '{{index .Labels "com.docker.compose.project"}}/{{index .Labels "com.docker.compose.volume"}}' $vol
docker run --rm -v $vol:/v:ro docker.io/library/alpine:3.22 cat /v/marker
rm /root/volumes/$vol.tar
RESTORE
			tail -n 2 "restore-$vol.log" | sed 's/^/    /'
			if [ "$(tail -n 1 "restore-$vol.log")" = "$vol" ] &&
				[ "$(tail -n 2 "restore-$vol.log" | head -n 1)" = "${vol%%_*}/${vol#*_}" ] &&
				printf '%s\n' "$password" | ssh_as gavin@127.0.0.1 "sudo -S -p '' test ! -e /root/volumes/$vol.tar"; then
				echo "PASS $vol is restored under Compose's labels and reads back"
			else
				echo "FAIL $vol did not read back as restored"
			fi
		else
			echo "FAIL could not restore $vol:"
			tail -n 5 "restore-$vol.log" | sed 's/^/    /'
		fi
	done
	cat > "$inv" <<INV
[fleet]
$host ansible_host=127.0.0.1 ansible_port=$static_port ansible_user=gavin ansible_ssh_private_key_file=$PWD/key ansible_ssh_common_args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'
[containerized]
$host
[control]
localhost
INV
	( umask 077; printf 'ansible_become_password: "%s"\n' "$password" > "$vars" )
	# ansible.cfg keeps ssh's shared connections there, as the control node has it.
	install -d -m 700 "$HOME/.ssh/cp"
	for dep in "${deployments[@]}"; do
		rc=0
		( cd "$repo/ansible" && ANSIBLE_CONFIG=$repo/ansible/ansible.cfg ansible-playbook \
			-i "$inv" playbooks/server-deploy-compose.yml -e "deployment=$dep" -e "@$vars" --check \
			) > "deploy-$dep.log" 2>&1 || rc=$?
		if grep -qF "$password" "deploy-$dep.log"; then
			echo "FAIL the sudo password appeared in $dep's play output"
			sed -i "s/$password/<password>/g" "deploy-$dep.log"
		fi
		tail -n 30 "deploy-$dep.log" | sed 's/^/    | /'
		[ "$rc" = 0 ] && echo "PASS the deploy play plans $dep" || echo "FAIL the deploy play could not plan $dep"
		# How far the plan got, in the play's own sentence, which prints whether or not it
		# reached Compose's dry run (the repo's callback hides a skipped task altogether).
		line=$(grep -m1 -oE "$dep on $host: (would change|nothing to change)[^|]*" "deploy-$dep.log" || true)
		echo "    plan: ${line:-no plan sentence in the log}"
	done
}
# A stage that cannot run is a FAIL in CI, where it always should, and a SKIP elsewhere.
skip() {
	if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "FAIL $*"; else echo "SKIP $*"; fi
}
deploy_plans 2>&1 | report

# ── rescue mode keeps a way in ───────────────────────────────────────────────
{
	echo "===== rescue mode"
	printf '%s\n' "$password" | ssh_as gavin@127.0.0.1 \
		"sudo -S -p '' systemctl --no-block isolate rescue.target" || true
	sleep 30
	wait_gavin
	as_root rescue.sh
	printf '%s\n' "$password" | ssh_as gavin@127.0.0.1 \
		"sudo -S -p '' systemctl --no-block isolate default.target" || true
	sleep 30
	wait_gavin
} 2>&1 | report

# ── a reboot ─────────────────────────────────────────────────────────────────
{
	echo "===== after a reboot"
	before=$(ssh_as gavin@127.0.0.1 cat /proc/sys/kernel/random/boot_id)
	printf '%s\n' "$password" | ssh_as gavin@127.0.0.1 "sudo -S -p '' systemctl reboot" || true
	sleep 30
	# From the second boot the host's own profile must hold: one's address is what every
	# client and sshd's PermitOpen name.
	wait_gavin static
	# A box still shutting down answers too; only a new boot id proves the checks below
	# are about the boot after.
	after=$(ssh_as gavin@127.0.0.1 cat /proc/sys/kernel/random/boot_id)
	[ "$before" != "$after" ] && echo "PASS the box rebooted" || echo "FAIL the box did not reboot"
	as_root checks.sh
	if declare -F sim_after_reboot >/dev/null; then sim_after_reboot; fi
} 2>&1 | report

kill "$(cat qemu.pid)" 2>/dev/null || true

if grep -q '^FAIL' report.txt; then
	echo "$(grep -c '^FAIL' report.txt) checks failed" >&2
	exit 1
fi
echo "every check passed"
