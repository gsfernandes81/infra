#!/bin/bash
# Runs inside the probe VM over ssh (run-probe.sh pipes it to `bash -s`). Prints a report
# section per question in plans/microos-cutover.md § What the simulation answers first.
# It keeps going past a failed check: the report is the point, not the exit status.
set -u

section() { printf '\n===== %s =====\n' "$1"; }
run() { printf '$ %s\n' "$*"; "$@" 2>&1; printf '[exit %s]\n' "$?"; }

section "system"
run cat /etc/os-release
run uname -r
run systemctl is-system-running
run systemctl --failed --no-legend

section "SELinux"
run getenforce
run sestatus

section "Docker"
run rpm -q docker docker-compose
run docker version --format '{{.Server.Version}}'
run docker compose version
run docker info --format 'driver={{.Driver}} root={{.DockerRootDir}} security={{.SecurityOptions}}'

section "bind mounts from an unlabelled btrfs at /media/simtest (the fleet's data arrives so)"
# A fresh filesystem has no SELinux labels, as the fleet's Alpine-made btrfs will not.
truncate -s 1G /var/tmp/simtest.img
run mkfs.btrfs -q /var/tmp/simtest.img
run mount -o loop /var/tmp/simtest.img /media/simtest
echo from-host > /media/simtest/f
mkdir -p /media/simtest/z && echo from-host > /media/simtest/z/f
run ls -dZ /media/simtest /media/simtest/f
echo "-- without a label, as every compose file here mounts:"
run docker run --rm -v /media/simtest:/data docker.io/library/alpine:3.20 \
	sh -c 'cat /data/f && echo from-container > /data/g && echo write-ok'
echo "-- with :z, which relabels the host path:"
run docker run --rm -v /media/simtest/z:/data:z docker.io/library/alpine:3.20 \
	sh -c 'cat /data/f && echo from-container > /data/g && echo write-ok'
run ls -dZ /media/simtest/z /media/simtest/z/f
echo "-- labelled by chcon, which writes the label into the data disk's xattrs:"
mkdir -p /media/simtest/c && echo from-host > /media/simtest/c/f
run chcon -R -t container_file_t /media/simtest/c
run docker run --rm -v /media/simtest/c:/data docker.io/library/alpine:3.20 \
	sh -c 'cat /data/f && echo from-container > /data/g && echo write-ok'
run ls -dZ /media/simtest/c/f /media/simtest/c/g
echo "-- labelled by the context= mount option, which writes nothing to the disk:"
run umount /media/simtest
truncate -s 1G /var/tmp/simctx.img
run mkfs.btrfs -q /var/tmp/simctx.img
run mount -o loop /var/tmp/simctx.img /media/simtest
echo from-host > /media/simtest/f
run umount /media/simtest
run mount -o loop,context=system_u:object_r:container_file_t:s0 /var/tmp/simctx.img /media/simtest
run ls -dZ /media/simtest /media/simtest/f
run docker run --rm -v /media/simtest:/data docker.io/library/alpine:3.20 \
	sh -c 'cat /data/f && echo from-container > /data/g && echo write-ok'
run umount /media/simtest
run mount -o loop /var/tmp/simctx.img /media/simtest
echo "-- the same disk mounted without context= afterwards, to show nothing was written:"
run ls -dZ /media/simtest/f /media/simtest/g

section "the bare mountpoint, with nothing mounted on it"
run umount /media/simtest
run touch /media/simtest/should-fail
run docker run --rm -v /media/simtest:/data docker.io/library/alpine:3.20 \
	sh -c 'echo x > /data/should-fail && echo WRITE-SUCCEEDED'
run ls -la /media/simtest

section "a compose stack shaped like the fleet's: a network, a published port, a shared namespace"
mkdir -p /root/stack
cat > /root/stack/compose.yaml <<'YAML'
name: simstack
services:
  web:
    # Alpine's busybox has no httpd applet, so the first try at this exited at once.
    image: docker.io/library/nginx:1.27-alpine
    ports: ["127.0.0.1:18080:80"]
  client:
    # Reaches web by its service name over the project network, as stacks here do.
    image: docker.io/library/alpine:3.20
    command: sh -c 'sleep 3; wget -qO- http://web/ && sleep 3600'
  sidecar:
    # Shares web's network namespace, as qBittorrent shares gluetun's.
    image: docker.io/library/alpine:3.20
    network_mode: "service:web"
    command: sh -c 'sleep 3; wget -qO- http://127.0.0.1/ && sleep 3600'
YAML
run docker compose -f /root/stack/compose.yaml up -d
sleep 10
run sh -c 'curl -fsS http://127.0.0.1:18080/ | grep -o "Welcome to nginx"'
run sh -c 'docker compose -f /root/stack/compose.yaml logs --no-color | tail -n 30'
run docker compose -f /root/stack/compose.yaml ps -a
run docker compose -f /root/stack/compose.yaml down
run rpm -q iptables nftables

section "upstream's Compose in /usr/local, as a host would carry it"
# Leap 16.1 ships Compose 2.33.1, below the 5.5.0 the deploy play requires
# (ansible/playbooks/_deploy-compose-one.yml). A host would carry upstream's static binary
# instead, pinned by version and SHA-256 as cloudflared is, in /usr/local, which takes writes
# outside a transactional-update shell only if it is a subvolume of its own. Docker's CLI
# looks in /usr/local/lib/docker/cli-plugins before openSUSE's /usr/lib/docker/cli-plugins.
# The pin is the fleet's version today; the SHA-256 is for the x86_64 binary this VM runs.
compose_ver=5.6.1
compose_sha=47737f4236e6d3ccea7291995203f8f018058783b4c3a9469119811a0b5db8c0
plugins=/usr/local/lib/docker/cli-plugins
run findmnt -T /usr/local -o TARGET,SOURCE,FSTYPE,OPTIONS
run curl -fsSL -o /var/tmp/docker-compose \
	"https://github.com/docker/compose/releases/download/v$compose_ver/docker-compose-linux-$(uname -m)"
run sh -c "echo '$compose_sha  /var/tmp/docker-compose' | sha256sum -c -"
run install -D -m 755 /var/tmp/docker-compose "$plugins/docker-compose"
run ls -lZ "$plugins/docker-compose"
run docker compose version
run sh -c "docker info --format '{{range .ClientInfo.Plugins}}{{.Name}} {{.Version}} {{.Path}}{{println}}{{end}}'"
echo "-- as a user who is not root, as the deploy play reads the version:"
run runuser -u nobody -- docker compose version --short
run rpm -q docker-buildx
echo "-- the fleet-shaped stack again, under upstream's Compose:"
run docker compose -f /root/stack/compose.yaml up -d
sleep 10
run sh -c 'curl -fsS http://127.0.0.1:18080/ | grep -o "Welcome to nginx"'
run docker compose -f /root/stack/compose.yaml ps -a
run docker compose -f /root/stack/compose.yaml down
echo "-- a build, which Compose 5 hands to buildx:"
mkdir -p /root/buildstack
printf 'FROM docker.io/library/alpine:3.20\nRUN echo built > /built\n' > /root/buildstack/Dockerfile
cat > /root/buildstack/compose.yaml <<'YAML'
name: simbuild
services:
  built:
    build: .
    image: simbuild:1
    command: cat /built
YAML
run docker compose -f /root/buildstack/compose.yaml build
run docker compose -f /root/buildstack/compose.yaml run --rm built
run docker compose -f /root/buildstack/compose.yaml down --rmi local
echo "-- a new snapshot, so the reboot below shows whether /usr/local carries over:"
run transactional-update --non-interactive run true

section "automatic updates and reboots"
run cat /root/rebootmgr.vendor.conf
run cat /etc/rebootmgr.conf
run rebootmgrctl get-strategy
run sh -c 'rpm -ql rebootmgr | grep -vE "/man/|/doc/|/licenses/"'
run sh -c 'ls -la /etc/rebootmgr* /usr/etc/rebootmgr* /usr/share/rebootmgr* 2>&1'
echo "-- set at runtime; the after-reboot section shows whether it persists:"
run rebootmgrctl set-strategy off
run rebootmgrctl get-strategy
run sh -c 'ls -la /etc/rebootmgr* 2>&1; cat /etc/rebootmgr.conf 2>&1'
run cat /usr/share/rebootmgr/rebootmgr.conf
run sh -c 'ls -la /etc/rebootmgr 2>&1; systemctl cat rebootmgr.service 2>&1 | head -n 30'
run rebootmgrctl status
run systemctl is-enabled transactional-update.timer
run systemctl list-timers transactional-update.timer --no-pager
run sh -c 'systemctl cat transactional-update.service 2>&1 | head -n 30'
run sh -c 'cat /etc/transactional-update.conf /usr/etc/transactional-update.conf 2>&1'
run sh -c 'ls -la /etc/rebootmgr/ 2>&1; cat /etc/transactional-update.conf 2>&1'

section "the daily update, run now: does the box stay up?"
boot_before=$(cat /proc/sys/kernel/random/boot_id)
run sh -c 'snapper list --columns number,description | tail -n 3'
run timeout 1200 systemctl start transactional-update.service
run systemctl status transactional-update.service --no-pager --lines 0
sleep 30
if [ "$(cat /proc/sys/kernel/random/boot_id)" = "$boot_before" ]; then
	echo "still up after the update: no reboot"
else
	echo "REBOOTED: boot id changed"
fi
run sh -c 'snapper list --columns number,description | tail -n 3'
run sh -c 'journalctl -u transactional-update.service --no-pager | grep -iE "reboot|snapshot" | tail -n 10'


section "bcache: does a udev rule register devices by itself?"
run rpm -q bcache-tools
run sh -c 'rpm -ql bcache-tools | grep -i rules'

section "sudo: whose password does it ask for?"
run sh -c 'rpm -qa | grep -i sudo | sort'
run sh -c 'grep -vE "^(#|$)" /etc/sudoers /usr/etc/sudoers 2>&1 | head -n 20'
run sh -c 'ls /etc/sudoers.d /usr/etc/sudoers.d 2>&1; cat /etc/sudoers.d/* /usr/etc/sudoers.d/* 2>/dev/null | grep -vE "^(#|$)"'
run sh -c 'getent group wheel; grep -E "^(UID_MIN|GID_MIN)" /etc/login.defs /usr/etc/login.defs 2>/dev/null'

section "packages a host needs"
for p in cloudflared bcache-tools smartmontools btrfsprogs docker docker-compose \
	zram-generator syncthing fish htop nano curl jq git; do
	run zypper --non-interactive --quiet search --match-exact "$p"
done

section "Leap's own defaults: the first-boot wizard, the firewall, the boot path, sshd, health-checker"
# jeos-firstboot runs only while reconfig_system exists, which Combustion removes when its
# script succeeds: "No such file" here means Combustion alone would have kept it away.
run cat /root/jeos-firstboot.unit
run ls -la /var/lib/YaST2/reconfig_system
run systemctl is-enabled jeos-firstboot.service
run systemctl is-active firewalld
run sh -c 'firewall-cmd --list-all 2>&1 | head -n 12'
run sh -c 'test -d /boot/efi/loader/entries && echo "BLS boot entries" || echo "no BLS entries: legacy GRUB"'
run sh -c 'grep -E "^GRUB_(TERMINAL|SERIAL|CMDLINE_LINUX_DEFAULT)" /etc/default/grub'
run sh -c 'sshd -T 2>/dev/null | grep -E "^(permitrootlogin|passwordauthentication|kbdinteractiveauthentication) "'
run sh -c 'rpm -qa | grep -iE "rootlogin|openssh" | sort'
run systemctl is-enabled health-checker.service
run sh -c 'ls /usr/libexec/health-checker/'
run sh -c 'cat /etc/tukit.conf /usr/etc/tukit.conf 2>/dev/null; ls /etc/tukit.conf.d /usr/etc/tukit.conf.d 2>&1'
run sh -c 'free -m; systemctl list-units --type=service --state=running --no-legend | wc -l'
