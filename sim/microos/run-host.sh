#!/bin/bash
# Sets a Leap 16.1 Immutable VM up as the routine sets up a Leap Pi (plans/pi-setup.md):
# boots the host's real first-boot script (hosts/<host>/leap/combustion/script) from a
# stick laid out as leap/make-stick lays it out but filled with stand-ins, then runs
# server-setup-leap.yml against it from the runner as the control node. Then it checks the
# box the two make: its ways in, its users and sudo, its disks and Docker, its pinned
# binaries, the play run again, and rescue mode. CI runs it (microos-sim.yml).
#
# Usage: sim/microos/run-host.sh <workdir> <host>
# It writes only inside <workdir>, except one loop mount under sudo to make the stand-in
# SSD's subvolumes, a play inventory in ansible/ while it runs, and for three a loop
# device, two mounts and two containers on the runner's network, one holding its port 22,
# for the stand-in for zero (host/three.sh).
# Every check prints PASS or FAIL; any FAIL fails the run.
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

# The play is the routine's second half, so without it there is no box to check.
command -v ansible-playbook >/dev/null ||
	{ echo "FAIL no ansible-playbook here; the setup play needs it" | report; exit 1; }

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
# make-stick --new's marker, which tells the first boot no tunnel credentials or key file
# are carried.
[ "$new_host" = no ] || : > "$c/NEW"
[ "$new_host" = yes ] || printf '{"AccountTag":"sim","TunnelSecret":"c2lt","TunnelID":"%s"}\n' \
	"$tunnel_id" > "$c/cloudflared/$host.json"
# Each deployment, and each other one make-stick carries that the deploy stage does not
# plan (host/<host>.sh's carried: one's dev stack).
for dep in "${deployments[@]}" "${carried[@]}"; do
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
# The first boot leaves the wired port on DHCP, as the image ships it, and the static
# profile comes from the play, at its second reboot. So the guest answers first on the
# address qemu's DHCP hands out, and from then on on its static one. The harness reaches
# each through a port of its own on 127.0.0.1 and tries both, so a box at the wrong one is
# still reached and examined, and reported as a FAIL. The port that answered is kept in a
# file, because the functions below run inside pipelines.
static_port=$ssh_port
dhcp_port=$((ssh_port + 1))
ssh_as() {
	ssh -q -i key -p "$(cat port 2>/dev/null || echo "$static_port")" \
		-o StrictHostKeyChecking=no -o UserKnownHostsFile=known \
		-o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 \
		-o BatchMode=yes "$@"
}
# Answers once gavin can log in with the run's key, and says at which address. With no
# argument the static address is expected, as from the play's second reboot on, and an
# answer at the DHCP one is a FAIL; `wait_gavin dhcp` expects the DHCP one, as the first
# boot leaves the box, and the other way round. `wait_gavin static` tries only the static.
wait_gavin() {
	local i p want=$static_port ports=("$static_port" "$dhcp_port")
	case "${1:-}" in
	static) ports=("$static_port") ;;
	dhcp) want=$dhcp_port ports=("$dhcp_port" "$static_port") ;;
	esac
	for i in $(seq 1 120); do
		for p in "${ports[@]}"; do
			echo "$p" > port
			if ssh_as gavin@127.0.0.1 true 2>/dev/null; then
				if [ "$p" = "$want" ] && [ "$p" = "$static_port" ]; then
					echo "gavin's ssh up after ~$((i * 5))s, on $sim_address"
				elif [ "$p" = "$want" ]; then
					echo "gavin's ssh up after ~$((i * 5))s, on the DHCP address $sim_dhcp_address"
				elif [ "$p" = "$static_port" ]; then
					echo "FAIL gavin's ssh answered on the static address before the play, not on DHCP"
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
		"sudo -S -p '' env EXPECT_UID=$expect_uid EXPECT_GID=$expect_gid EXPECT_CLOUDFLARED=$expect_cloudflared EXPECT_COMPOSE=$expect_compose EXPECT_NEW_HOST=$new_host bash /tmp/sim-$script $*"
}
# Runs shell on the guest as root, the same way: root_sh '<commands>'.
root_sh() {
	{ printf '%s\n' "$password"; printf '%s\n' "$1"; } | ssh_as gavin@127.0.0.1 "sudo -S -p '' bash -s"
}
boot_id() { ssh_as gavin@127.0.0.1 cat /proc/sys/kernel/random/boot_id; }
# Where a tracked file of this host lives on the box, from its infra- header.
live_path() {
	local f=$repo/hosts/$host/leap/system/$1
	echo "$(sed -n 's/^# infra-path:[[:space:]]*//p' "$f")/$(sed -n 's/^# infra-name:[[:space:]]*//p' "$f")"
}

# What checks.sh compares against, read from the files the box was made from.
expect_uid=$(sed -n 's/^gavin_uid=//p' "$repo/hosts/$host/leap/combustion/script")
expect_gid=$(sed -n 's/^gavin_gid=//p' "$repo/hosts/$host/leap/combustion/script")
expect_cloudflared=$(sed -n 's/^cloudflared_version=//p' "$repo/leap/pins")
expect_compose=$(sed -n 's/^compose_version=//p' "$repo/leap/pins")

rm -f known
sim_netdev="user,id=n0,net=$sim_net,host=$sim_gateway,dns=$sim_dns"
sim_netdev+=",hostfwd=tcp:127.0.0.1:$static_port-$sim_address:22"
sim_netdev+=",hostfwd=tcp:127.0.0.1:$dhcp_port-$sim_dhcp_address:22"
# And for the setup play, each guest address at 127.0.0.<its last number> (below).
play_static=127.0.0.${sim_address##*.}
play_dhcp=127.0.0.${sim_dhcp_address##*.}
sim_netdev+=",hostfwd=tcp:$play_static:$ssh_port-$sim_address:22"
sim_netdev+=",hostfwd=tcp:$play_dhcp:$ssh_port-$sim_dhcp_address:22"
sim_serial_socket=$PWD/serial.sock
boot_vm "${disk_args[@]}"
wait_gavin dhcp | report

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

# ── the setup play ───────────────────────────────────────────────────────────
# server-setup-leap.yml, from the runner as the control node, as the owner runs it on the
# day: logged in as gavin, with his sudo password given as -K gives it, at the box's DHCP
# address. The runner reaches each guest address at 127.0.0.<its last number>, on one
# port, and the play is given the static address in that form, so its own reconnect rule
# moves its connection at the reboot that brings the static profile in, as it does on the
# LAN. -e confirm=yes answers its questions, except where a run below proves a refusal,
# and -e ways_in_check=false skips the two checks a simulation cannot pass, as in the
# update play.
#
# On the day the box clones its checkout from GitHub at main, which is the control node's
# commit. Here the commit under test is on a branch or is a pull request's merge commit,
# so gavin's git on the box is pointed at a copy of it instead: a bare repository the
# runner sends before the play, holding that commit as the branch sim-under-test, and a
# url.insteadOf line for GitHub's address. The clone is still the play's own, and the
# system files play finds the box on the commit it reviewed, as it requires.
setup_inv=$repo/ansible/inventory.sim-setup
setup_vars=$PWD/setup-become.yml
# Removed however the run ends: the vars file holds the sudo password, and a stale
# inventory in ansible/ would be read by the next local run.
trap 'rm -f "$setup_inv" "$setup_vars"' EXIT
cat > "$setup_inv" <<INV
[fleet]
$host ansible_host=$play_static ansible_port=$ssh_port ansible_user=gavin ansible_ssh_private_key_file=$PWD/key ansible_ssh_common_args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'
[containerized]
$host
[leap]
$host
[control]
localhost
INV
( umask 077; printf 'ansible_become_password: "%s"\n' "$password" > "$setup_vars" )
# ansible.cfg keeps ssh's shared connections there, as the control node has it.
install -d -m 700 "$HOME/.ssh/cp"
# One run: setup_run <label> [ansible-playbook argument]... Its log is setup-<label>.log
# and its exit status setup_rc. No terminal, so a question the run does not answer with
# confirm=yes is refused, as a no would refuse it. The wide COLUMNS keeps the repo's
# callback from wrapping a line the checks look for.
setup_run() {
	local label=$1
	shift
	setup_rc=0
	( cd "$repo/ansible" && COLUMNS=400 ANSIBLE_CONFIG=$repo/ansible/ansible.cfg ansible-playbook \
		-i "$setup_inv" playbooks/server-setup-leap.yml -e "target=$host" -e "@$setup_vars" \
		-e ways_in_check=false -e "leap_static_address=$play_static" "$@" \
		) < /dev/null > "setup-$label.log" 2>&1 || setup_rc=$?
	if grep -qF "$password" "setup-$label.log"; then
		echo "FAIL the sudo password appeared in the setup play's output ($label)"
		sed -i "s/$password/<password>/g" "setup-$label.log"
	fi
	grep -E 'Tracked files changed|Restarted where|Reboot for|NOT REBOOTED|On no list|REFUSED by|Failed units|Error' \
		"setup-$label.log" | sed 's/^ */    | /'
	[ "$setup_rc" = 0 ] || tail -n 40 "setup-$label.log" | sed 's/^/    ! /'
}

setup_first() {
	local before after sha
	set +e
	echo "===== the setup play, from the runner, at the box's DHCP address"
	sha=$(git -C "$repo" rev-parse HEAD)
	# scp, since the image has no tar.
	if ! { rm -rf seed && mkdir seed && git init -q --bare seed/.sim-infra.git &&
		git -C seed/.sim-infra.git config receive.shallowUpdate true &&
		git -C "$repo" push -q "$PWD/seed/.sim-infra.git" "$sha:refs/heads/sim-under-test" &&
		git -C seed/.sim-infra.git symbolic-ref HEAD refs/heads/sim-under-test &&
		scp -q -r -i key -P "$(cat port)" -o StrictHostKeyChecking=no -o UserKnownHostsFile=known \
			-o BatchMode=yes seed/.sim-infra.git gavin@127.0.0.1:/home/gavin/ &&
		printf '[url "/home/gavin/.sim-infra.git"]\n\tinsteadOf = https://github.com/gsfernandes81/infra.git\n' |
		ssh_as gavin@127.0.0.1 'cat > /home/gavin/.gitconfig'; } > seed.log 2>&1; then
		echo "FAIL could not give the box a copy of the commit under test, $sha:"
		sed 's/^/    /' seed.log
	fi
	before=$(boot_id)
	setup_run first -e confirm=yes -e "ansible_host=$play_dhcp"
	[ "$setup_rc" = 0 ] && echo "PASS the setup play set $host up" ||
		echo "FAIL the setup play failed (exit $setup_rc)"
	wait_gavin static
	after=$(boot_id)
	[ -n "$after" ] && [ "$before" != "$after" ] && echo "PASS the play rebooted the box" ||
		echo "FAIL the box did not reboot"
	grep -q "If the address moves: reconnect at $play_static" setup-first.log &&
		echo "PASS the play reconnected at the static address by its own rule" ||
		echo "FAIL the play did not reconnect at the static address"
	[ "$(ssh_as gavin@127.0.0.1 git -C infra rev-parse HEAD)" = "$sha" ] &&
		echo "PASS the play's clone is on the commit under test" ||
		echo "FAIL the play's clone is not on the commit under test"
}
setup_first 2>&1 | report

{ echo "===== the box the routine made"; as_root checks.sh; } 2>&1 | report

# ── the play again ───────────────────────────────────────────────────────────
# Safe to run again, and the way a Pi is changed after: a second run changes nothing; a
# changed tracked file restarts its service by the rule, but not sshd; a package on no list
# is reported and left; a package added to the list is installed.
setup_again() {
	local before after def pids now line
	set +e
	echo "===== the setup play again"
	before=$(boot_id)
	def=$(root_sh 'btrfs subvolume get-default /')
	setup_run second -e confirm=yes
	if [ "$setup_rc" = 0 ] && [ "$(boot_id)" = "$before" ] &&
		[ "$(root_sh 'btrfs subvolume get-default /')" = "$def" ] &&
		! grep -q 'build the package snapshot' setup-second.log &&
		grep -q 'Tracked files changed: none\.' setup-second.log; then
		echo "PASS a second run installs nothing, changes no tracked file and does not reboot"
	else
		echo "FAIL a second run changed something or rebooted (exit $setup_rc)"
	fi

	# A hand edit to two tracked files: rebootmgr.conf, whose service the rule restarts,
	# and sshd-infra.conf, which waits for the reboot. No confirm=yes, so it is refused.
	pids=$(root_sh 'systemctl show -p MainPID --value rebootmgr sshd' | grep . | paste -sd' ')
	root_sh "echo '# sim: a hand edit' >> $(live_path rebootmgr.conf)
		echo '# sim: a hand edit' >> $(live_path sshd-infra.conf)"
	setup_run restart
	now=$(root_sh 'systemctl show -p MainPID --value rebootmgr sshd' | grep . | paste -sd' ')
	echo "    MainPID of rebootmgr and sshd: $pids before, $now after"
	[ "$setup_rc" = 0 ] && [ "$(boot_id)" = "$before" ] && grep -q 'NOT REBOOTED' setup-restart.log &&
		echo "PASS the play asks before the reboot, and a no leaves the box running" ||
		echo "FAIL the refused reboot did not leave the box running (exit $setup_rc)"
	root_sh "! grep -q 'sim: a hand edit' $(live_path rebootmgr.conf) $(live_path sshd-infra.conf)" &&
		echo "PASS both hand-edited files are put back" || echo "FAIL a hand-edited file was not put back"
	[ "${now%% *}" != 0 ] && [ "${now%% *}" != "${pids%% *}" ] &&
		echo "PASS a changed rebootmgr.conf restarts rebootmgr" ||
		echo "FAIL rebootmgr was not restarted"
	[ "${now##* }" != 0 ] && [ "${now##* }" = "${pids##* }" ] &&
		echo "PASS a changed sshd-infra.conf does not restart sshd" ||
		echo "FAIL sshd was restarted, or is not running"

	# tmux, installed by hand, and tree, added to the list for one run. A hand install is
	# booted into like any transactional-update, and the play builds its snapshot on the
	# running system, so the box boots into tmux before the run.
	if root_sh 'rpm -q tmux || rpm -q tree' > /dev/null; then
		echo "FAIL tmux or tree is in the image, so neither shows the list or the report"
	fi
	root_sh 'transactional-update --non-interactive pkg install tmux' > tmux.log 2>&1 ||
		{ echo "FAIL could not install tmux by hand:"; tail -n 10 tmux.log | sed 's/^/    /'; }
	before=$(boot_id)
	root_sh 'systemctl reboot' || true
	sleep 30
	wait_gavin static
	[ "$(boot_id)" != "$before" ] || echo "FAIL the box did not reboot into tmux"
	# The list as group_vars/leap.yml has it, and tree.
	printf '%s\n' "leap_packages: \"{{ (lookup('ansible.builtin.file', control_checkout" \
		"~ '/ansible/group_vars/leap.yml') | from_yaml).leap_packages + ['tree'] }}\"" > setup-list.yml
	setup_run list -e confirm=yes -e "@$PWD/setup-list.yml"
	wait_gavin static
	[ "$setup_rc" = 0 ] && root_sh 'rpm -q tree' > /dev/null &&
		echo "PASS a package added to the list is installed by the next run" ||
		echo "FAIL tree, added to the list, was not installed (exit $setup_rc)"
	line=$(grep -o 'On no list[^:]*: [^.]*' setup-list.log | head -n 1)
	echo "    ${line:-no extras line in the report}"
	case " ${line#*: } " in
	*" tmux "*) case " ${line#*: } " in *" tree "*) false ;; *) true ;; esac ;;
	*) false ;;
	esac && root_sh 'rpm -q tmux' > /dev/null &&
		echo "PASS a package installed by hand is reported as an extra and left installed" ||
		echo "FAIL tmux was not reported as an extra and left, or tree was reported"
}
setup_again 2>&1 | report

# What the visit does next on this host, if host/<host>.sh says: on three, its tunnel and
# its array.
if declare -F sim_after_setup >/dev/null; then
	sim_after_setup 2>&1 | report
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

# ── the update play ──────────────────────────────────────────────────────────
# server-update-leap.yml, for real, from the runner as the control node. Both pinned
# binaries are first swapped for stand-ins that report version 0.0.0-sim, so the play has
# something to move and the previous it keeps can be told from the pin. -e confirm=yes
# answers its question, and -e ways_in_check=false skips the two checks a simulation cannot
# pass: a stand-in tunnel never connects, and there is no tailnet.
update_play() {
	local inv=$repo/ansible/inventory.sim-host vars=$PWD/become.yml rc before after
	trap 'rm -f "$inv" "$vars"' EXIT
	echo "===== the update play"
	if ! command -v ansible-playbook >/dev/null; then
		skip "no ansible-playbook here"
		return 0
	fi
	{ printf '%s\n' "$password"; cat <<'STUBS'; } | ssh_as gavin@127.0.0.1 "sudo -S -p '' bash -s" 2>&1 | sed 's/^/    /' || true
set -e
# Each beside its binary, then renamed over it: cloudflared restarts every 10 s with the
# stand-in credentials, and a write into it while it runs fails "Text file busy".
printf '#!/bin/sh\necho "cloudflared version 0.0.0-sim (stand-in)"\n' > /usr/local/bin/cloudflared.sim
printf '#!/bin/sh\necho 0.0.0-sim\n' > /usr/local/lib/docker/cli-plugins/docker-compose.sim
chmod 755 /usr/local/bin/cloudflared.sim /usr/local/lib/docker/cli-plugins/docker-compose.sim
mv -f /usr/local/bin/cloudflared.sim /usr/local/bin/cloudflared
mv -f /usr/local/lib/docker/cli-plugins/docker-compose.sim /usr/local/lib/docker/cli-plugins/docker-compose
# A stale copy of the update recipes, so only the play's own install can make it current.
echo stale > /etc/motd.d/50-infra-updates
STUBS
	cat > "$inv" <<INV
[fleet]
$host ansible_host=127.0.0.1 ansible_port=$static_port ansible_user=gavin ansible_ssh_private_key_file=$PWD/key ansible_ssh_common_args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'
[containerized]
$host
[control]
localhost
INV
	( umask 077; printf 'ansible_become_password: "%s"\n' "$password" > "$vars" )
	install -d -m 700 "$HOME/.ssh/cp"
	before=$(ssh_as gavin@127.0.0.1 cat /proc/sys/kernel/random/boot_id)
	# --check first: it must read and report, and change nothing.
	rc=0
	( cd "$repo/ansible" && ANSIBLE_CONFIG=$repo/ansible/ansible.cfg ansible-playbook \
		-i "$inv" playbooks/server-update-leap.yml -e "target=$host" -e "@$vars" --check \
		) > update-check.log 2>&1 || rc=$?
	sed -i "s/$password/<password>/g" update-check.log
	if [ "$rc" = 0 ] && grep -q 'DRY RUN' update-check.log &&
		[ "$(ssh_as gavin@127.0.0.1 cat /proc/sys/kernel/random/boot_id)" = "$before" ] &&
		ssh_as gavin@127.0.0.1 /usr/local/bin/cloudflared --version | grep -q 0.0.0-sim; then
		echo "PASS --check reports and changes nothing"
	else
		echo "FAIL --check failed or changed something (exit $rc):"
		tail -n 20 update-check.log | sed 's/^/    | /'
	fi
	rc=0
	( cd "$repo/ansible" && ANSIBLE_CONFIG=$repo/ansible/ansible.cfg ansible-playbook \
		-i "$inv" playbooks/server-update-leap.yml -e "target=$host" -e confirm=yes \
		-e ways_in_check=false -e "@$vars" ) > update.log 2>&1 || rc=$?
	if grep -qF "$password" update.log; then
		echo "FAIL the sudo password appeared in the update play's output"
		sed -i "s/$password/<password>/g" update.log
	fi
	tail -n 40 update.log | sed 's/^/    | /'
	[ "$rc" = 0 ] && echo "PASS the update play updated and rebooted $host" ||
		echo "FAIL the update play failed (exit $rc)"
	wait_gavin static
	after=$(ssh_as gavin@127.0.0.1 cat /proc/sys/kernel/random/boot_id)
	[ "$before" != "$after" ] && echo "PASS the play rebooted the box" || echo "FAIL the box did not reboot"
	grep -q 'NOT CHECKED (-e ways_in_check=false)' update.log &&
		echo "PASS the play's report says the ways in were not checked" ||
		echo "FAIL the play's report does not say the ways in were skipped"
	if [ "$host" = three ]; then
		grep -q 'The array is locked; unlock it as hosts/three/leap/README.md' update.log &&
			echo "PASS the play ends with the unlock command" ||
			echo "FAIL the play does not end with the unlock command"
	fi
	# An interactive login, with no command: given one, sshd shows no motd at all.
	if printf 'exit\n' | ssh -tt -i key -p "$(cat port)" -o StrictHostKeyChecking=no -o UserKnownHostsFile=known \
		-o BatchMode=yes gavin@127.0.0.1 2>&1 | grep -q 'Updates on this box are by hand'; then
		echo "PASS a login shows the update recipes"
	else
		echo "FAIL a login does not show the update recipes"
	fi
	as_root update-checks.sh
}
update_play 2>&1 | report

kill "$(cat qemu.pid)" 2>/dev/null || true

if grep -q '^FAIL' report.txt; then
	echo "$(grep -c '^FAIL' report.txt) checks failed" >&2
	exit 1
fi
echo "every check passed"
