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
	grep -rl -- "$token" stick | xargs -r sed -i "s|$token|${standin[$token]}|g"
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
openssl passwd -6 "$(openssl rand -hex 12)" > "$c/shadow/root"
openssl passwd -6 "$password" > "$c/shadow/gavin"
cp key.pub "$c/gavin/authorized_keys"
printf '{"AccountTag":"sim","TunnelSecret":"c2lt","TunnelID":"%s"}\n' "$tunnel_id" \
	> "$c/cloudflared/$host.json"
for dep in "${deployments[@]}"; do
	printf 'SIM_STANDIN=1\n' > "$c/env/$dep.env"
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
ssh_as() {
	ssh -q -i key -p "$ssh_port" -o StrictHostKeyChecking=no -o UserKnownHostsFile=known \
		-o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 \
		-o BatchMode=yes "$@"
}
# Answers once gavin can log in with the run's key.
wait_gavin() {
	local i
	for i in $(seq 1 120); do
		if ssh_as gavin@127.0.0.1 true 2>/dev/null; then
			echo "gavin's ssh up after ~$((i * 5))s"
			return 0
		fi
		sleep 5
	done
	echo "FAIL gavin cannot log in after 10 minutes; serial log follows"
	tail -n 80 serial.log
	return 1
}
# Runs a script on the guest as root through gavin's sudo, which reads his password first.
as_root() {
	ssh_as gavin@127.0.0.1 "cat > /tmp/sim-$1" < "$here/host/$1"
	printf '%s\n' "$password" | ssh_as gavin@127.0.0.1 "sudo -S -p '' bash /tmp/sim-$1"
}

rm -f known
sim_netdev="user,id=n0,net=$sim_net,host=$sim_gateway,dns=$sim_dns,hostfwd=tcp:127.0.0.1:${ssh_port}-$sim_address:22"
boot_vm "${disk_args[@]}"
wait_gavin | report

# ── what only the runner can see ─────────────────────────────────────────────
{
	echo "===== from outside"
	want=$(awk '{print $2}' "$c/ssh/ssh_host_ed25519_key.pub")
	have=$(ssh-keyscan -t ed25519 -p "$ssh_port" 127.0.0.1 2>/dev/null | awk '{print $3}')
	[ "$want" = "$have" ] && echo "PASS the host key is the carried one" \
		|| echo "FAIL the host key is not the carried one"
	if ssh_as -o PubkeyAuthentication=no gavin@127.0.0.1 true 2> pw.err; then
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
	else
		echo "PASS root is refused over ssh with a valid key in place"
	fi
	printf '%s\n' "$password" | ssh_as gavin@127.0.0.1 "sudo -S -p '' rm -f /root/.ssh/authorized_keys"
} 2>&1 | report

{ echo "===== first boot"; as_root checks.sh; } 2>&1 | report

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
	printf '%s\n' "$password" | ssh_as gavin@127.0.0.1 "sudo -S -p '' systemctl reboot" || true
	sleep 30
	wait_gavin
	as_root checks.sh
} 2>&1 | report

kill "$(cat qemu.pid)" 2>/dev/null || true

if grep -q '^FAIL' report.txt; then
	echo "$(grep -c '^FAIL' report.txt) checks failed" >&2
	exit 1
fi
echo "every check passed"
