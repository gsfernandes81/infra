#!/bin/bash
# pass and fail always succeed, so `A && pass || fail` can never run both.
# shellcheck disable=SC2015,SC2016  # SC2016: commands for the box are single-quoted on purpose
# The encrypted member of zero's array, as far as a container can take it
# (plans/visit-runbook.md § Slice 2): Alpine 3.24's own cryptsetup and dmcrypt service, the
# tracked /etc/conf.d/dmcrypt, bcache-register and dm-crypt.conf, and install-system-file's
# dmcrypt check, against a LUKS2 volume on a loop device standing in for zero's /dev/bcacheN.
# Prints PASS or FAIL per check and exits 1 on any FAIL. sim/alpine/README.md § The
# encrypted member says what it proves and what it cannot.
#
# It builds and runs a privileged container and attaches a loop device on the runner, so it
# belongs on a throwaway runner, never on the control node or a fleet host.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
work=${RUNNER_TEMP:-/tmp}/dmcrypt-sim
box=infra-dmcrypt-sim
# The runbook's own names and flags (plans/visit-runbook.md § Slice 2), so a change there
# that this file does not follow shows as a difference in review.
key=/etc/keys/data.key
target=data-4
label=data-luks-4
format_flags='--batch-mode --type luks2 --cipher xchacha12,aes-adiantum-plain64 --key-size 256 --pbkdf-memory 262144'
fails=0

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
on() { docker exec "$box" sh -c "$1"; }
tool() { on "su gavin -c 'cd /home/gavin/infra && bin/install-system-file $1'" 2>&1; }

if [ -e "$work" ] || docker inspect "$box" >/dev/null 2>&1; then
	echo "refusing: $work or a container named $box already exists" >&2
	exit 1
fi
mkdir -p "$work"
loop=
cleanup() {
	docker rm -f "$box" >/dev/null 2>&1
	[ -n "$loop" ] && sudo losetup -d "$loop" 2>/dev/null
	rm -rf "$work"
}
trap cleanup EXIT

# ── the runner's kernel ────────────────────────────────────────────────────
# The container shares it. dm-crypt and btrfs are loaded here; Adiantum's modules load by
# algorithm name when cryptsetup first asks for the cipher, as on zero.
sudo modprobe dm_crypt && sudo modprobe btrfs || { echo "the runner cannot load dm_crypt or btrfs" >&2; exit 1; }
# The loop device is made on the runner, before the container starts, so its node is in
# the privileged container's /dev. 256 MiB: LUKS2's 16 MiB header and a btrfs.
truncate -s 256M "$work/member.img"
loop=$(sudo losetup --show -f "$work/member.img") || { echo "no loop device" >&2; exit 1; }
echo "== the stand-in for zero's /dev/bcacheN is $loop"

# ── the box ────────────────────────────────────────────────────────────────
docker build -q -t infra-alpine-sim "$here/host" >/dev/null || { echo "image build failed" >&2; exit 1; }
docker run -d --name "$box" --hostname zero --privileged infra-alpine-sim >/dev/null || exit 1
for _ in $(seq 1 30); do on 'test -e /run/openrc/softlevel' && break; sleep 1; done
# bcache-register needs `dev`, which mdev provides on zero and nothing provides here.
on "sed -i 's/^rc_provide=.*/rc_provide=\"loopback net dev\"/' /etc/rc.conf"
on 'apk add -q --no-cache cryptsetup cryptsetup-openrc btrfs-progs btrfs-progs-openrc' || { echo "apk add failed" >&2; exit 1; }
# zero has it already, for bcache.ko.
on 'mkdir -p /etc/modules-load.d'
docker cp "$repo" "$box:/home/gavin/infra" && on 'chown -R gavin:gavin /home/gavin/infra'
conf=/home/gavin/infra/hosts/zero/system/dmcrypt
echo "   cryptsetup $(on 'cryptsetup --version')"

# ── the key file, as the runbook makes it ──────────────────────────────────
echo "== the key file"
on "install -d -m 700 /etc/keys && (umask 077; dd if=/dev/urandom of=$key bs=512 count=8 status=none) && chmod 400 $key"
[ "$(on "stat -c '%a %u %s' $key")" = "400 0 4096" ] && pass "$key is root's, 0400, 4096 bytes" || fail "$key is $(on "stat -c '%a %u %s' $key")"
[ "$(on 'stat -c %a /etc/keys')" = 700 ] && pass "/etc/keys is 0700" || fail "/etc/keys is $(on 'stat -c %a /etc/keys')"

# ── the format, the passphrase slot, the header ────────────────────────────
echo "== luksFormat with the key file, Adiantum, label $label"
if on "cryptsetup luksFormat $format_flags --label $label --key-file $key $loop"; then
	pass "luksFormat with xchacha12,aes-adiantum-plain64"
else
	fail "luksFormat refused the runbook's flags"
	grep -E '^name' /proc/crypto | sort -u | grep -iE 'adiantum|chacha|nhpoly' | sed 's/^/    | /'
fi
# The owner types the passphrase at the runbook's prompt; here it comes from a file.
on "printf %s sim-passphrase-not-real > /run/pass && chmod 600 /run/pass"
on "cryptsetup luksAddKey --batch-mode --pbkdf-memory 262144 --key-file $key $loop /run/pass" && pass "luksAddKey added a passphrase slot" || fail "luksAddKey failed"
on "cryptsetup luksDump $loop" > "$work/dump"
grep -Eq '^[[:space:]]+cipher:[[:space:]]+xchacha12,aes-adiantum-plain64' "$work/dump" && pass "luksDump: cipher xchacha12,aes-adiantum-plain64" || fail "luksDump shows another cipher"
grep -Eq "^Label:[[:space:]]+$label\$" "$work/dump" && pass "luksDump: label $label" || fail "luksDump shows another label"
slots=$(grep -cE '^  [0-9]+: luks2' "$work/dump")
[ "$slots" = 2 ] && pass "luksDump: two keyslots" || fail "luksDump: $slots keyslots"
grep -Eq '^[[:space:]]+Memory:[[:space:]]+262144' "$work/dump" && pass "luksDump: argon2 memory 262144 KiB, which a 1 GB board can open" || fail "luksDump: the keyslots' memory is not 262144 KiB"
on "cryptsetup open --test-passphrase --key-file /run/pass $loop" && pass "the passphrase opens it" || fail "the passphrase does not open it"
uuid=$(on "cryptsetup luksUUID $loop")
echo "   LUKS UUID $uuid"

# ── findfs, the way dmcrypt resolves source= ───────────────────────────────
echo "== findfs UUID=, BusyBox's (and util-linux's below)"
[ "$(on "findfs UUID=$uuid")" = "$loop" ] && pass "BusyBox findfs finds the LUKS2 UUID on $loop" || fail "BusyBox findfs: '$(on "findfs UUID=$uuid" 2>&1)'"

echo "== a btrfs inside, opened by the key file"
on "cryptsetup open --key-file $key $loop sim-open && mkfs.btrfs -q -L data /dev/mapper/sim-open && mkdir -p /mnt/sim && mount /dev/mapper/sim-open /mnt/sim && echo kept > /mnt/sim/proof && umount /mnt/sim && cryptsetup close sim-open" \
	&& pass "open, mkfs.btrfs, write, close" || fail "the round trip failed"

# ── install-system-file's dmcrypt check, calibrated ────────────────────────
echo "== install-system-file dmcrypt: the refusals, then the good entry"
said=$(tool 'dmcrypt --allow-content-change')
case "$said" in *'FILL-FROM- placeholder is left in'*) pass "refused the repo's placeholder" ;; *) fail "did not refuse the placeholder: $said" ;; esac
on "sed -i 's/FILL-FROM-LUKS-UUID/$uuid/' $conf"
on "cp $conf /run/dmcrypt.filled"
said=$(tool 'dmcrypt --allow-content-change')
case "$said" in *'pre-checks on the repo copy: ok'*'DRY RUN'*) pass "the filled entry passes, dry run" ;; *) fail "the filled entry did not pass: $said" ;; esac

on "sed -i 's/$uuid/00000000-0000-4000-8000-000000000000/' $conf"
said=$(tool 'dmcrypt --allow-content-change')
case "$said" in *'finds no device'*) pass "refused a UUID nothing has" ;; *) fail "did not refuse an unknown UUID: $said" ;; esac
on "cp /run/dmcrypt.filled $conf && sed -i '/^key=/d' $conf"
said=$(tool 'dmcrypt --allow-content-change')
case "$said" in *'no key='*) pass "refused an entry with no key=, which would ask at the console" ;; *) fail "did not refuse a missing key=: $said" ;; esac
on "cp /run/dmcrypt.filled $conf && chmod 644 $key"
said=$(tool 'dmcrypt --allow-content-change')
case "$said" in *'it must be root'*) pass "refused a key file others can read" ;; *) fail "did not refuse a 0644 key file: $said" ;; esac
on "chmod 400 $key && cp $key /run/key.real && (umask 077; dd if=/dev/urandom of=$key bs=512 count=8 status=none)"
said=$(tool 'dmcrypt --allow-content-change')
case "$said" in *'does not open'*) pass "refused a key file that does not open the volume" ;; *) fail "did not refuse a wrong key: $said" ;; esac
on "cp -p /run/key.real $key && chmod 400 $key"

said=$(tool 'dmcrypt --allow-content-change --commit')
case "$said" in *'post-install checks: ok'*) pass "installed over cryptsetup-openrc's /etc/conf.d/dmcrypt" ;; *) fail "the install failed: $said" ;; esac
on "cmp -s $conf /etc/conf.d/dmcrypt" && pass "/etc/conf.d/dmcrypt is the filled repo copy" || fail "/etc/conf.d/dmcrypt differs"
said=$(tool 'bcache-register --new --commit')
case "$said" in *'post-install checks: ok'*) pass "installed bcache-register" ;; *) fail "bcache-register: $said" ;; esac
said=$(tool 'dm-crypt.conf --new --commit')
case "$said" in *'post-install checks: ok'*) pass "installed dm-crypt.conf" ;; *) fail "dm-crypt.conf: $said" ;; esac

# ── OpenRC's order, by starting the boot runlevel ──────────────────────────
# Each service's link in /run/openrc/started is made as its start finishes. bcache-register
# waits its 30 s for devices that never come here, then always exits 0.
echo "== the boot runlevel: bcache-register, then dmcrypt, then btrfs-scan"
on 'rc-update -q add bcache-register boot; rc-update -q add dmcrypt boot; rc-update -q add btrfs-scan boot; rc-update -u' >/dev/null
on 'openrc boot' > "$work/boot.log" 2>&1
sed 's/^/    | /' "$work/boot.log"
order=$(on 'cd /run/openrc/started && python3 -I -c "
import os
names = [\"bcache-register\", \"dmcrypt\", \"btrfs-scan\"]
t = {n: os.lstat(n).st_mtime_ns for n in names if os.path.lexists(n)}
print(\" \".join(sorted(t, key=t.get)))"')
[ "$order" = "bcache-register dmcrypt btrfs-scan" ] && pass "started in that order" || fail "started in the order '$order'"
on "test -b /dev/mapper/$target" && pass "dmcrypt opened /dev/mapper/$target with the key file" || fail "no /dev/mapper/$target after dmcrypt started"
[ "$(on "mount /dev/mapper/$target /mnt/sim && cat /mnt/sim/proof; umount /mnt/sim")" = kept ] && pass "the btrfs inside reads back" || fail "the btrfs inside did not read back"

# ── a boot that cannot unlock still finishes ───────────────────────────────
echo "== dmcrypt with the key file missing, then with a wrong one"
on 'rc-service dmcrypt stop' >/dev/null 2>&1
on "test ! -e /dev/mapper/$target" && pass "dmcrypt stop closed the mapping" || fail "the mapping is still open after stop"
on "mv $key /run/key.away"
if timeout 60 docker exec "$box" rc-service dmcrypt start >/dev/null 2>&1; then
	pass "a missing key file: dmcrypt returns, skipping the entry"
else
	[ $? -eq 124 ] && fail "a missing key file: dmcrypt was still waiting after 60 s" || pass "a missing key file: dmcrypt returns, reporting a failure"
fi
on "test ! -e /dev/mapper/$target" && pass "and nothing is mapped" || fail "something was mapped without the key"
on 'rc-service dmcrypt zap' >/dev/null 2>&1
on "(umask 077; dd if=/dev/urandom of=$key bs=512 count=8 status=none)"
timeout 60 docker exec "$box" rc-service dmcrypt start >/dev/null 2>&1
rc=$?
[ "$rc" -eq 124 ] && fail "a wrong key: dmcrypt was still waiting after 60 s" || pass "a wrong key: dmcrypt returns (exit $rc), asking nobody"
on "test ! -e /dev/mapper/$target" && pass "and nothing is mapped" || fail "something was mapped with a wrong key"
on "cp -p /run/key.away $key && rc-service dmcrypt zap" >/dev/null 2>&1

# ── util-linux's findfs, the other one zero may have ───────────────────────
echo "== findfs UUID=, util-linux's"
on 'apk add -q --no-cache util-linux-misc' >/dev/null
[ "$(on "findfs UUID=$uuid")" = "$loop" ] && pass "util-linux findfs finds the LUKS2 UUID too" || fail "util-linux findfs: '$(on "findfs UUID=$uuid" 2>&1)'"

echo
if [ "$fails" -gt 0 ]; then echo "$fails check(s) FAILED"; exit 1; fi
echo "all checks passed"
