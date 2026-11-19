#!/bin/bash
# Prints one SHA-256 over a tree: every path with its owner, group, mode and type, each
# file's size, and each file's contents. host/three.sh runs it as root on the runner's
# snapshot of zero's Immich and on three's copy of it; the two lines must be equal.
#
# --fake-super reads the tree as a restore would: it is first copied, as root, with rsync's
# --fake-super on the reading side, which turns the owners and modes the pull kept in an
# xattr back into real ones, and the copy is hashed. Three's copy is the backup user's on
# disk, so without it every owner would read as that user's.
#
# Left out on both sides: .snapshots, each box's own, and the placeholders a snapshot holds
# for its nested subvolumes (data/thumbs, data/encoded-video), which three-backup.sh checks
# on its own. A symlink counts by its name and type alone: three stores its target munged
# (mirror-pull's --munge-links), and a user xattr, where the pull keeps an owner, cannot be
# set on a symlink, so its owner is not kept.
#
# Usage: tree-hash.sh [--fake-super] <directory>
set -euo pipefail
if [ "${1-}" = --fake-super ]; then
	shift
	tmp=$(mktemp -d /var/tmp/tree-hash.XXXXXX)
	trap 'rm -rf "$tmp"' EXIT
	# No -X: the copy lands on Leap's /var, labelled by SELinux, and rsync would try to make
	# its security.selinux match the source's. --fake-super reads the kept owners without it.
	rsync -aH --numeric-ids --fake-super -M--super --exclude=/.snapshots \
		"${1:?usage: tree-hash.sh [--fake-super] <directory>}/" "$tmp/"
	set -- "$tmp"
fi
cd "${1:?usage: tree-hash.sh [--fake-super] <directory>}"
skip=(\( -path ./.snapshots -o -path ./data/thumbs -o -path ./data/encoded-video \) -prune -o)
{
	find . "${skip[@]}" -type l -printf '%P l\n' -o -type f -printf '%P %U:%G %m f %s\n' \
		-o -printf '%P %U:%G %m %y\n' | LC_ALL=C sort
	find . "${skip[@]}" -type f -print0 | LC_ALL=C sort -z | xargs -0r sha256sum
} | sha256sum | cut -d' ' -f1
