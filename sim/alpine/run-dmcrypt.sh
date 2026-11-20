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
format_flags='--batch-mode --type luks2 --cipher xchacha12,aes-adiantum-plain64 --key-size 256 --sector-size 4096 --pbkdf-memory 262144'
fails=0

# The LUKS UUID the stand-in is formatted with: the one the tracked entry names, so the file
# installed on zero is checked as it is, byte for byte. Before zero's member existed the
# entry carried FILL-FROM-LUKS-UUID, and a fresh UUID stands in for that. Anything else, or
# more than one entry, is refused: this stands in for one member, and a guess would check
# a file that is not the tracked one.
tracked_conf=$repo/hosts/zero/system/dmcrypt
[ "$(grep -c '^target=' "$tracked_conf")" = 1 ] || { echo "refusing: $tracked_conf does not have exactly one entry (target=)" >&2; exit 1; }
[ "$(grep -c '^source=' "$tracked_conf")" = 1 ] || { echo "refusing: $tracked_conf does not have exactly one source=" >&2; exit 1; }
source_line=$(grep '^source=' "$tracked_conf")
case "$source_line" in
	"source='UUID=FILL-FROM-LUKS-UUID'") uuid=$(cat /proc/sys/kernel/random/uuid) ;;
	*) uuid=$(printf %s "$source_line" | sed -n "s/^source='UUID=\([0-9a-f]\{8\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{12\}\)'\$/\1/p") ;;
esac
[ -n "$uuid" ] || { echo "refusing: $tracked_conf has $source_line, neither a LUKS UUID nor the placeholder" >&2; exit 1; }
filled="source='UUID=$uuid'"

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

# ── the entry, filled, and refused while no volume has its UUID ────────────
# Filling replaces the source= line; once the tracked entry names zero's UUID it changes
# nothing, and that is checked, so the entry installed below is the tracked file itself.
# Refused here, before the format, so the pass after it comes from the volume carrying the
# UUID and not from a check that passes anything.
echo "== the entry names UUID $uuid; refused while no volume has it"
on "cp $conf /run/dmcrypt.tracked && sed -i \"s|^source=.*|$filled|\" $conf && cp $conf /run/dmcrypt.filled"
if [ "$source_line" = "$filled" ]; then
	on "cmp -s /run/dmcrypt.tracked /run/dmcrypt.filled" && pass "the tracked entry names a UUID, and is checked unchanged" || fail "filling changed the tracked entry"
fi
said=$(tool 'dmcrypt --allow-content-change')
case "$said" in *"findfs UUID=$uuid finds no device"*) pass "refused while no volume has the UUID" ;; *) fail "did not refuse the entry before the format: $said" ;; esac

# ── the format, the passphrase slot, the header ────────────────────────────
# --uuid is the one flag the runbook does not have: zero's volume got its UUID from its own
# luksFormat, and the stand-in takes that UUID so the tracked entry resolves to it.
echo "== luksFormat with the key file, Adiantum, label $label, UUID $uuid"
if on "cryptsetup luksFormat $format_flags --label $label --uuid $uuid --key-file $key $loop"; then
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
grep -Eq '^[[:space:]]+sector:[[:space:]]+4096' "$work/dump" && pass "luksDump: sector 4096" || fail "luksDump: the sector is not 4096"
grep -Eq '^[[:space:]]+Memory:[[:space:]]+262144' "$work/dump" && pass "luksDump: argon2 memory 262144 KiB, which a 1 GB board can open" || fail "luksDump: the keyslots' memory is not 262144 KiB"
on "cryptsetup open --test-passphrase --key-file /run/pass $loop" && pass "the passphrase opens it" || fail "the passphrase does not open it"
[ "$(on "cryptsetup luksUUID $loop")" = "$uuid" ] && pass "luksUUID: $uuid, the entry's" || fail "luksUUID: '$(on "cryptsetup luksUUID $loop" 2>&1)', not $uuid"

# ── findfs, the way dmcrypt resolves source= ───────────────────────────────
echo "== findfs UUID=, BusyBox's (and util-linux's below)"
[ "$(on "findfs UUID=$uuid")" = "$loop" ] && pass "BusyBox findfs finds the LUKS2 UUID on $loop" || fail "BusyBox findfs: '$(on "findfs UUID=$uuid" 2>&1)'"

echo "== a btrfs inside, opened by the key file"
on "cryptsetup open --key-file $key $loop sim-open && mkfs.btrfs -q -L data /dev/mapper/sim-open && mkdir -p /mnt/sim && mount /dev/mapper/sim-open /mnt/sim && echo kept > /mnt/sim/proof && umount /mnt/sim && cryptsetup close sim-open" \
	&& pass "open, mkfs.btrfs, write, close" || fail "the round trip failed"

# ── install-system-file's dmcrypt check, calibrated ────────────────────────
echo "== install-system-file dmcrypt: the refusals, then the good entry"
on "sed -i \"s|^source=.*|source='UUID=FILL-FROM-LUKS-UUID'|\" $conf"
said=$(tool 'dmcrypt --allow-content-change')
case "$said" in *'FILL-FROM- placeholder is left in'*) pass "refused the placeholder" ;; *) fail "did not refuse the placeholder: $said" ;; esac
on "cp /run/dmcrypt.filled $conf"
said=$(tool 'dmcrypt --allow-content-change')
case "$said" in *'pre-checks on the repo copy: ok'*'DRY RUN'*) pass "the filled entry passes, dry run" ;; *) fail "the filled entry did not pass: $said" ;; esac

on "sed -i 's/$uuid/00000000-0000-4000-8000-000000000000/' $conf"
said=$(tool 'dmcrypt --allow-content-change')
case "$said" in *'finds no device'*) pass "refused a UUID nothing has" ;; *) fail "did not refuse an unknown UUID: $said" ;; esac
on "cp /run/dmcrypt.filled $conf && sed -i '/^key=/d' $conf"
said=$(tool 'dmcrypt --allow-content-change')
case "$said" in *'no key='*) pass "refused an entry with no key=, which would ask at the console" ;; *) fail "did not refuse a missing key=: $said" ;; esac
on "cp /run/dmcrypt.filled $conf && sed -i 's|^key=.*|key=/home/gavin/data.key|' $conf"
said=$(tool 'dmcrypt --allow-content-change')
case "$said" in *'outside /etc'*) pass "refused a key file outside /etc" ;; *) fail "did not refuse a key outside /etc: $said" ;; esac
on "cp /run/dmcrypt.filled $conf && sed -i 's|^target=|tagret=|' $conf"
said=$(tool 'dmcrypt --allow-content-change')
case "$said" in *'not a setting dmcrypt reads'*) pass "refused a name dmcrypt does not read" ;; *) fail "did not refuse an unknown name: $said" ;; esac
on "cp /run/dmcrypt.filled $conf && chmod 644 $key"
said=$(tool 'dmcrypt --allow-content-change')
case "$said" in *'it must be root'*) pass "refused a key file others can read" ;; *) fail "did not refuse a 0644 key file: $said" ;; esac
on "chmod 400 $key && cp $key /run/key.real && (umask 077; dd if=/dev/urandom of=$key bs=512 count=8 status=none)"
said=$(tool 'dmcrypt --allow-content-change')
case "$said" in *'does not open'*) pass "refused a key file that does not open the volume" ;; *) fail "did not refuse a wrong key: $said" ;; esac
on "cp -p /run/key.real $key && chmod 400 $key"

said=$(tool 'dmcrypt --allow-content-change --commit')
case "$said" in *'post-install checks: ok'*) pass "installed over cryptsetup-openrc's /etc/conf.d/dmcrypt" ;; *) fail "the install failed: $said" ;; esac
on "cmp -s /run/dmcrypt.filled /etc/conf.d/dmcrypt" && pass "/etc/conf.d/dmcrypt is the filled entry" || fail "/etc/conf.d/dmcrypt differs from the filled entry"
said=$(tool 'bcache-register --new --commit')
case "$said" in *'post-install checks: ok'*) pass "installed bcache-register" ;; *) fail "bcache-register: $said" ;; esac
said=$(tool 'dm-crypt.conf --new --commit')
case "$said" in *'post-install checks: ok'*) pass "installed dm-crypt.conf" ;; *) fail "dm-crypt.conf: $said" ;; esac

# ── OpenRC's order, by starting the boot runlevel ──────────────────────────
# Each service's link in /run/openrc/started is made as its start finishes. bcache-register
# waits its 30 s for devices that never come here, then always exits 0.
echo "== the boot runlevel: bcache-register, then dmcrypt, then btrfs-scan"
on 'rc-update -q add bcache-register boot; rc-update -q add dmcrypt boot; rc-update -q add btrfs-scan boot; rc-update -u' >/dev/null
# The runbook's step 8 reads dmcrypt's recorded order with this grep; its output is checked
# here so the runbook's command is known to read the deptree's real format.
on "grep \"^depinfo_\$(grep \"_service='dmcrypt'\" /run/openrc/deptree | cut -d_ -f2)_i\" /run/openrc/deptree" > "$work/deptree"
sed 's/^/    | /' "$work/deptree"
grep -q "_iafter_[0-9]*='bcache-register'" "$work/deptree" && grep -q "_iafter_[0-9]*='modules'" "$work/deptree" \
	&& pass "the deptree has dmcrypt after bcache-register and modules" || fail "the deptree lacks dmcrypt's iafter lines"
# localmount and fsck carry `keyword -docker`, so OpenRC leaves them out of a container's
# deptree altogether (the first run showed checkfs, btrfs-scan and local); on zero they are
# there. btrfs-scan is the one that matters for the array, and it has no such keyword.
grep -q "_ibefore_[0-9]*='btrfs-scan'" "$work/deptree" \
	&& pass "the deptree has dmcrypt before btrfs-scan" || fail "the deptree lacks dmcrypt's ibefore btrfs-scan"
on 'openrc boot' > "$work/boot.log" 2>&1
sed 's/^/    | /' "$work/boot.log"
order=$(on 'cd /run/openrc/started && python3 -I -c "
import os
names = [\"bcache-register\", \"dmcrypt\", \"btrfs-scan\"]
t = {n: os.lstat(n).st_mtime_ns for n in names if os.path.lexists(n)}
print(\" \".join(sorted(t, key=t.get)))"')
[ "$order" = "bcache-register dmcrypt btrfs-scan" ] && pass "started in that order" || fail "started in the order '$order'"
on "test -b /dev/mapper/$target" && pass "dmcrypt opened /dev/mapper/$target with the key file" || fail "no /dev/mapper/$target after dmcrypt started"
grep -q "registered: /dev/mapper/$target" "$work/boot.log" && pass "btrfs-scan, after it, registered /dev/mapper/$target" || fail "btrfs-scan did not register /dev/mapper/$target"
[ "$(on "mount /dev/mapper/$target /mnt/sim && cat /mnt/sim/proof; umount /mnt/sim")" = kept ] && pass "the btrfs inside reads back" || fail "the btrfs inside did not read back"

# ── a boot that cannot unlock still finishes ───────────────────────────────
# Each check reads dmcrypt's own words as well as its exit, since a conf with no entry also
# returns at once and maps nothing: the red runs after 016125c passed both checks that way.
echo "== dmcrypt with the key file missing, then with a wrong one"
on 'rc-service dmcrypt stop' >/dev/null 2>&1
on "test ! -e /dev/mapper/$target" && pass "dmcrypt stop closed the mapping" || fail "the mapping is still open after stop"
on "mv $key /run/key.away"
timeout 60 docker exec "$box" rc-service dmcrypt start >"$work/missing.log" 2>&1
rc=$?
if [ "$rc" -eq 124 ]; then
	fail "a missing key file: dmcrypt was still waiting after 60 s"
elif grep -q "Reason: keyfile $key does not exist" "$work/missing.log"; then
	pass "a missing key file: dmcrypt returns (exit $rc), skipping the entry for that reason"
else
	fail "a missing key file: dmcrypt returned (exit $rc) without naming the missing key: $(cat "$work/missing.log")"
fi
on "test ! -e /dev/mapper/$target" && pass "and nothing is mapped" || fail "something was mapped without the key"
on 'rc-service dmcrypt zap' >/dev/null 2>&1
on "(umask 077; dd if=/dev/urandom of=$key bs=512 count=8 status=none)"
timeout 60 docker exec "$box" rc-service dmcrypt start >"$work/wrong.log" 2>&1
rc=$?
if [ "$rc" -eq 124 ]; then
	fail "a wrong key: dmcrypt was still waiting after 60 s"
elif [ "$rc" -ne 0 ] && grep -q "$target using:" "$work/wrong.log"; then
	pass "a wrong key: dmcrypt tried the entry and returns (exit $rc), asking nobody"
else
	fail "a wrong key: dmcrypt returned (exit $rc) without failing an attempt on $target: $(cat "$work/wrong.log")"
fi
on "test ! -e /dev/mapper/$target" && pass "and nothing is mapped" || fail "something was mapped with a wrong key"
on "cp -p /run/key.away $key && rc-service dmcrypt zap" >/dev/null 2>&1

# ── util-linux's findfs, the other one zero may have ───────────────────────
echo "== findfs UUID=, util-linux's"
on 'apk add -q --no-cache util-linux-misc' >/dev/null
[ "$(on "findfs UUID=$uuid")" = "$loop" ] && pass "util-linux findfs finds the LUKS2 UUID too" || fail "util-linux findfs: '$(on "findfs UUID=$uuid" 2>&1)'"

echo
if [ "$fails" -gt 0 ]; then echo "$fails check(s) FAILED"; exit 1; fi
echo "all checks passed"
