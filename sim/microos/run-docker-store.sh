#!/bin/bash
# Whether MicroOS's Docker can take over the /var/lib/docker that Alpine's Docker leaves on
# the fleet's SSDs: makes the store with Alpine 3.24's package (docker-store/make-store.sh),
# boots MicroOS with it attached, and runs docker-store/checks.sh. CI runs it
# (.github/workflows/microos-sim.yml).
#
# Usage: sim/microos/run-docker-store.sh <workdir>. It writes only inside <workdir>, apart
# from a temporary mountpoint make-store.sh removes.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
work=${1:?usage: run-docker-store.sh <workdir>}
mkdir -p "$work"
cd "$work"

# shellcheck source=sim/microos/lib.sh
. "$here/lib.sh"

"$here/docker-store/make-store.sh" "$PWD/store.img" 2>&1 | tee report.txt
fetch_image
make_config_drive "$here/docker-store"
boot_vm -drive "file=$PWD/store.img,if=virtio,format=raw,serial=simstore"
wait_for_ssh
ssh_vm 'systemctl is-system-running --wait' || true
ssh_vm 'bash -s' < "$here/docker-store/checks.sh" | tee -a report.txt

kill "$(cat qemu.pid)" 2>/dev/null || true
