#!/bin/bash
# Prints one SHA-256 over a tree: every path with its owner, group, mode and type, each
# file's size, and each file's contents. host/three.sh runs it as root on the runner's
# snapshot and on three's received copy of it; the two lines must be equal. The placeholders
# a snapshot holds for its nested subvolumes (data/thumbs, data/encoded-video, config) are
# left out on both sides, since three-backup.sh checks what became of them on its own.
#
# Usage: tree-hash.sh <directory>
set -euo pipefail
cd "${1:?usage: tree-hash.sh <directory>}"
nested=(\( -path ./data/thumbs -o -path ./data/encoded-video -o -path ./config \) -prune -o)
{
	find . "${nested[@]}" -type f -printf '%P %U:%G %m f %s\n' -o -printf '%P %U:%G %m %y\n' | LC_ALL=C sort
	find . "${nested[@]}" -type f -print0 | LC_ALL=C sort -z | xargs -0r sha256sum
} | sha256sum | cut -d' ' -f1
