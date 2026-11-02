#!/bin/bash
# Runs on the CI runner, with sudo for the loop mount: builds a /var/lib/docker the way
# Alpine 3.24's own Docker package leaves it on the fleet (containerd image store, on
# btrfs), holding what a host carries: a pulled image, a named volume with data, a locally
# made image, and an exited container. The VM then mounts it as its own.
#
# Usage: make-store.sh <store.img>
set -euo pipefail

img=${1:?usage: make-store.sh <store.img>}
mnt=$(mktemp -d)
# Unmount and remove the mountpoint however the script ends, so a failed run on a dev box
# leaves no loop mount behind.
cleanup() { sudo umount "$mnt" 2>/dev/null || true; rmdir "$mnt" 2>/dev/null || true; }
trap cleanup EXIT
truncate -s 3G "$img"
mkfs.btrfs -q "$img"
sudo mount -o loop "$img" "$mnt"

# Alpine's dockerd inside a privileged Alpine container, writing straight into the image.
# No bridge and no iptables: the store is the point, not the network.
docker run --rm --privileged -v "$mnt:/var/lib/docker" docker.io/library/alpine:3.24 sh -euxc '
	apk add --no-cache docker >/dev/null
	mkdir -p /etc/docker
	echo "{\"features\": {\"containerd-snapshotter\": true}}" > /etc/docker/daemon.json
	dockerd --iptables=false --ip6tables=false --bridge=none >/var/log/dockerd.log 2>&1 &
	for _ in $(seq 1 60); do docker info >/dev/null 2>&1 && break; sleep 1; done
	docker version --format "alpine docker: server {{.Server.Version}}"
	containerd --version
	docker info --format "alpine docker: driver={{.Driver}} {{.DriverStatus}}"
	docker pull -q docker.io/library/alpine:3.20
	docker volume create simvol
	docker run --rm --network none -v simvol:/v docker.io/library/alpine:3.20 \
		sh -c "echo from-alpine-docker > /v/f"
	docker run --network none --name keep docker.io/library/alpine:3.20 \
		sh -c "echo made-locally > /made && echo keep-ran"
	docker commit keep local/sim:1
	docker images
	docker ps -a
	kill -TERM "$(cat /var/run/docker.pid)"
	for _ in $(seq 1 30); do [ -e /var/run/docker.pid ] || break; sleep 1; done
'
