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

section "bind mount into /media, as the compose files do (no :z label)"
mkdir -p /media/simtest && echo from-host > /media/simtest/f
run docker run --rm -v /media/simtest:/data docker.io/library/alpine:3.20 \
	sh -c 'cat /data/f && echo from-container > /data/g && echo write-ok'
run ls -lZ /media/simtest

section "automatic updates and reboots"
run cat /root/rebootmgr.vendor.conf
run cat /etc/rebootmgr.conf
run rebootmgrctl get-strategy
run systemctl is-enabled transactional-update.timer
run systemctl list-timers transactional-update.timer --no-pager

section "bcache: does a udev rule register devices by itself?"
run rpm -q bcache-tools
run sh -c 'rpm -ql bcache-tools | grep -i rules'

section "packages a host needs"
for p in cloudflared bcache-tools smartmontools btrfsprogs docker docker-compose \
	zram-generator syncthing; do
	run zypper --non-interactive --quiet search --match-exact "$p"
done
