#!/bin/bash
# shellcheck disable=SC2016  # the checks are shell code for sh -c, quoted on purpose
# Runs on the simulated host as root (run-host.sh sends it through gavin's sudo) and prints
# PASS or FAIL per check, reading what to expect from the box's own files, so it serves
# every host. Detail follows a FAIL, indented.
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
show() { printf '$ %s\n' "$*"; "$@" 2>&1 | sed 's/^/  /'; }

echo "-- the box"
show sh -c '. /etc/os-release; echo "$PRETTY_NAME"; uname -r; hostname'
check "systemd reached running, nothing failed" sh -c '
	s=$(systemctl is-system-running --wait); f=$(systemctl --failed --no-legend --plain)
	echo "state: $s"; echo "$f"
	for u in $(echo "$f" | awk "{print \$1}"); do journalctl -b --no-pager -u "$u" | tail -n 12; done
	[ "$s" = running ] && [ -z "$f" ]'
# Which address is up is the harness's to judge: the first boot may still run the
# initramfs's DHCP connection, and from the second boot only the static one is accepted.
show ip -4 -br addr
show nmcli -f NAME,DEVICE,ACTIVE,FILENAME connection show
show sh -c 'journalctl -b -u NetworkManager --no-pager | grep -iE "policy|activation|keyfile|wired|initrd" | tail -n 15'
check "SELinux enforces" sh -c '[ "$(getenforce)" = Enforcing ]'

echo "-- users and sudo"
show id gavin
check "gavin's shell is fish" sh -c 'getent passwd gavin | tee /dev/stderr | grep -q ":/usr/bin/fish$"'
check "gavin's sudo asks for his own password" sh -c 'sudo -l -U gavin | tee /dev/stderr | grep -q "!targetpw"'
check "root has a password, for the console" sh -c 'passwd -S root | tee /dev/stderr | grep -qE "^root P"'
check "root has no ssh key" sh -c '! test -s /root/.ssh/authorized_keys'

echo "-- sshd"
show sh -c 'sshd -T | grep -E "^(permitrootlogin|passwordauthentication|kbdinteractiveauthentication|allowtcpforwarding|permitopen) "'
check "sshd refuses root, passwords and keyboard-interactive" sh -c '
	t=$(sshd -T); echo "$t" | grep -qx "permitrootlogin no" && echo "$t" | grep -qx "passwordauthentication no" &&
	echo "$t" | grep -qx "kbdinteractiveauthentication no"'

echo "-- data mounts, one per fstab entry below /media and for Docker's store"
awk '$2 ~ "^/media/" || $2 == "/var/lib/docker" { print $2 }' /etc/fstab | while read -r m; do
	check "$m is mounted, by subvolid" sh -c "findmnt -no SOURCE,OPTIONS '$m' | tee /dev/stderr | grep -q subvolid="
done
# Data entries only: the image's own root entries use subvol= and are always mounted.
check "no data entry names a subvol=, which health-checker's plugin would act on" sh -c '
	! awk '\''$2 ~ "^/media/" || $2 == "/var/lib/docker" || $2 == "/mnt"'\'' /etc/fstab |
		grep -E "[[:space:],]subvol="'
check "swap on the SSD is on" sh -c 'swapon --show --noheadings | tee /dev/stderr | grep -q "^/dev/sd"'
if [ -e /etc/systemd/zram-generator.conf ]; then
	check "zram swap is on, ahead of the SSD's" sh -c '
		swapon --show=NAME,PRIO --noheadings | tee /dev/stderr | grep -qE "^/dev/zram0 +100$"'
fi
check "the bare /media refuses a write" sh -c '! touch /media/sim-write-test 2>/dev/null'

echo "-- Docker"
check "Docker runs, on the store on the SSD" sh -c '
	systemctl is-active docker && findmnt -no SOURCE /var/lib/docker | tee /dev/stderr | grep -q "/var-lib-docker-leap"'
check "a container runs from a fresh pull into that store" \
	docker run --rm docker.io/library/alpine:3.20 true
check "a container reads the data through the context= mount" sh -c '
	f=$(find /media -maxdepth 2 -name marker | head -n1); [ -n "$f" ] || exit 1
	docker run --rm -v "$(dirname "$f"):/d:ro" docker.io/library/alpine:3.20 cat /d/marker'
check "Compose is upstream's, from /usr/local" sh -c "
	docker info --format '{{range .ClientInfo.Plugins}}{{.Name}} {{.Version}} {{.Path}}{{println}}{{end}}' |
	tee /dev/stderr | grep -q '^compose .* /usr/local/lib/docker/cli-plugins/docker-compose$'"
check "openSUSE's docker-compose is not installed" sh -c '! rpm -q docker-compose'

echo "-- the two ways in"
check "cloudflared is the pinned binary, enabled" sh -c '
	/usr/local/bin/cloudflared --version; systemctl is-enabled cloudflared'
check "the tunnel's ingress validates" \
	/usr/local/bin/cloudflared tunnel --config /etc/cloudflared/config.yml ingress validate
show systemctl status cloudflared --no-pager --lines 3
check "tailscaled runs, from Tailscale's repo" sh -c '
	systemctl is-active tailscaled && rpm -q --qf "%{VENDOR}\n" tailscale | tee /dev/stderr | grep -qi tailscale'
show sh -c 'firewall-cmd --list-all 2>&1 | head -n 10'

echo "-- reboots and updates are the owner's"
check "the update timer is masked" sh -c '
	s=$(systemctl is-enabled transactional-update.timer); echo "$s"; [ "$s" = masked ]'
check "rebootmgr's strategy is off" sh -c 'rebootmgrctl get-strategy | tee /dev/stderr | grep -q off'
check "jeos-firstboot is masked" sh -c '[ "$(systemctl is-enabled jeos-firstboot.service)" = masked ]'

echo "-- the checkout and the carry-over"
check "the checkout is gavin's" sh -c '[ "$(stat -c %U /home/gavin/infra)" = gavin ] && git -C /home/gavin/infra log --oneline -1'
check "each .env is in place at 0600" sh -c '
	n=0; for f in /home/gavin/infra/deployments/*/.env; do
		[ -e "$f" ] || continue; n=$((n+1)); stat -c "%a %U %n" "$f"; [ "$(stat -c %a "$f")" = 600 ] || exit 1
	done; [ "$n" -gt 0 ]'
check "each secrets directory is gavin's" sh -c '
	ls -d /home/gavin/.*-secrets && [ -z "$(find /home/gavin/.*-secrets ! -user gavin)" ]'
check "the volume tars wait in /root/volumes" sh -c 'ls -l /root/volumes/*.tar'
check "the tunnel credentials are root's alone" sh -c 'stat -c "%a %U %n" /etc/cloudflared/*.json | tee /dev/stderr | grep -qv "^600 root" && exit 1 || true'
