#!/bin/bash
# Runs in the VM over ssh: stops MicroOS's Docker, mounts the Alpine-made store (the
# VM disk with the serial simstore) as /var/lib/docker, and reports what the newer store still gives
# an older Docker. Keeps going past a failed check.
set -u
run() { printf '$ %s\n' "$*"; "$@" 2>&1; printf '[exit %s]\n' "$?"; }

run docker version --format 'this image'"'"'s docker: server {{.Server.Version}}'
run rpm -q containerd docker
run systemctl stop docker.socket docker.service
run mount /dev/disk/by-id/virtio-simstore /var/lib/docker
run ls -dZ /var/lib/docker /var/lib/docker/volumes
echo "-- started as the store arrives, with no SELinux labels:"
run systemctl start docker.service
run docker info --format 'driver={{.Driver}} {{.DriverStatus}}'
run docker images
run docker volume ls
run docker ps -a
run docker run --rm --network none -v simvol:/v docker.io/library/alpine:3.20 cat /v/f
run docker run --rm --network none local/sim:1 cat /made
run docker start -a keep
echo "-- after restorecon gives the store the policy's labels:"
run systemctl stop docker.socket docker.service
run sh -c 'restorecon -R /var/lib/docker && echo relabelled'
run ls -dZ /var/lib/docker /var/lib/docker/volumes
run systemctl start docker.service
run docker images
run docker run --rm --network none -v simvol:/v docker.io/library/alpine:3.20 cat /v/f
run docker run --rm --network none local/sim:1 cat /made
run docker start -a keep
run sh -c 'journalctl -u docker --no-pager | grep -iE "error|fail|migrat" | tail -n 15'
echo "-- the same, with a fresh copy of the pulled image: is it the store or its image layers?"
run sh -c 'dmesg | grep -iE "segfault|avc:.*denied" | tail -n 5'
# ausearch reads stdin when it is not a terminal, and stdin here is this script.
run sh -c 'ausearch --input-logs -m avc -ts recent < /dev/null 2>&1 | tail -n 5'
run docker run --rm --network none docker.io/library/alpine:3.20 true
run docker rmi -f docker.io/library/alpine:3.20
run docker pull -q docker.io/library/alpine:3.20
run docker run --rm --network none -v simvol:/v docker.io/library/alpine:3.20 cat /v/f
run docker run --rm --network none docker.io/library/busybox:1.37 cat /proc/version
