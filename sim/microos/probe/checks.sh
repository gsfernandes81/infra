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
echo "-- labelled once by a policy rule instead, so the compose files keep their mounts:"
mkdir -p /media/simtest/p && echo from-host > /media/simtest/p/f
run sh -c 'command -v semanage restorecon chcon'
run semanage fcontext -a -t container_file_t '/media/simtest/p(/.*)?'
run restorecon -R -v /media/simtest/p
run docker run --rm -v /media/simtest/p:/data docker.io/library/alpine:3.20 \
	sh -c 'cat /data/f && echo from-container > /data/g && echo write-ok'
run ls -dZ /media/simtest/p /media/simtest/p/f /media/simtest/p/g

section "the bare mountpoint, with nothing mounted on it"
run umount /media/simtest
run touch /media/simtest/should-fail
run docker run --rm -v /media/simtest:/data docker.io/library/alpine:3.20 \
	sh -c 'echo x > /data/should-fail && echo WRITE-SUCCEEDED'
run ls -la /media/simtest

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
run sh -c 'grep -n -i reboot /usr/share/transactional-update/transactional-update.conf 2>&1 | head'


section "bcache: does a udev rule register devices by itself?"
run rpm -q bcache-tools
run sh -c 'rpm -ql bcache-tools | grep -i rules'

section "packages a host needs"
for p in cloudflared bcache-tools smartmontools btrfsprogs docker docker-compose \
	zram-generator syncthing; do
	run zypper --non-interactive --quiet search --match-exact "$p"
done
