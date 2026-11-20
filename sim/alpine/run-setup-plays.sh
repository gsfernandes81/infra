#!/bin/bash
# pass and fail always succeed, so `A && pass || fail` can never run both.
# shellcheck disable=SC2015,SC2016  # SC2016: commands for the box are single-quoted on purpose
# Runs the setup plays end to end against an Alpine container with OpenRC as init, reached
# over ssh as a fleet host is: server-install-tailscale.yml, server-create-restore-key.yml and
# server-store-backup-ntfy-url.yml, and server-install-system-files.yml's dry run; then
# zero's snapper install as hosts/zero/system/README.md gives it, install-system-file's
# sudoers check, server-start-dev-containers.yml, and server-unlock-arrays.yml, refused on the
# box's OpenRC and run for real on the runner's systemd. Prints PASS or FAIL per check and
# exits 1 on any FAIL.
# CI runs it on an arm64 runner (.github/workflows/alpine-sim.yml), so the real pinned
# tarball's binaries run in the container as they would on zero. sim/alpine/README.md says
# what each part proves and what it cannot.
#
# It builds and runs a privileged container, binds 127.0.0.1:2222, and writes
# ansible/inventory.sim and ~/.ssh/cp, so it belongs on a throwaway runner.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
work=${RUNNER_TEMP:-/tmp}/alpine-sim
port=8788
box=infra-alpine-sim
srv="http://host.docker.internal:$port"
# A key real Tailscale must refuse, and the one the stand-in accepts.
bad_key=tskey-auth-kSIMnotreal-0000000000000000000000000000000000
good_key=tskey-auth-kSIMstandin-1111111111111111111111111111111111
ntfy_secret=backup-sim-topic-7f3c9e1a
fails=0

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
on() { docker exec "$box" sh -c "$1"; }

if [ -e "$work" ] || docker inspect "$box" >/dev/null 2>&1; then
	echo "refusing: $work or a container named $box already exists" >&2
	exit 1
fi
mkdir -p "$work/pkgs" "$HOME/.ssh/cp"
cleanup() {
	[ -n "${srv_pid-}" ] && kill "$srv_pid" 2>/dev/null
	docker rm -f "$box" >/dev/null 2>&1
	docker network rm infra-sim-tailnet >/dev/null 2>&1
	rm -f "$repo/ansible/inventory.sim" "$repo/ansible/play.log" "$repo/ansible/play-verbose.log"
}
trap cleanup EXIT

# ── the pin ────────────────────────────────────────────────────────────────
vars="$repo/ansible/group_vars/fleet.yml"
pin_version=$(sed -n 's/^tailscale_static_version: "\(.*\)"$/\1/p' "$vars")
pin_sha=$(sed -n 's/^tailscale_static_sha256_aarch64: *//p' "$vars")
echo "== the pin, $pin_version, against Tailscale's tarball"
real="tailscale_${pin_version}_arm64"
if curl -fsSL --retry 3 -o "$work/$real.tgz" "https://pkgs.tailscale.com/stable/$real.tgz"; then
	[ "$(sha256sum "$work/$real.tgz" | awk '{print $1}')" = "$pin_sha" ] && pass "group_vars' SHA-256 is the tarball's" || fail "the tarball's SHA-256 is not group_vars'"
	# A listing in a file: grep -q ends the pipe early, and pipefail counts tar's SIGPIPE.
	tar -tzf "$work/$real.tgz" > "$work/listing"
	grep -qx "$real/tailscaled" "$work/listing" && grep -qx "$real/tailscale" "$work/listing" \
		&& pass "the tarball holds $real/tailscaled and tailscale" || fail "the tarball's layout is not $real/{tailscaled,tailscale}"
else
	fail "could not download $real.tgz"
fi
rm -f "$work/$real.tgz"

# ── the stand-in tarballs ──────────────────────────────────────────────────
case "$(uname -m)" in aarch64) arch=arm64 ;; x86_64) arch=amd64 ;; *) echo "unknown arch" >&2; exit 1 ;; esac
sha_key="tailscale_static_sha256_$(uname -m)"
fake() {
	local v=$1 d="$work/build/tailscale_${1}_$arch"
	mkdir -p "$d"
	for b in tailscale tailscaled; do
		sed "s/@VERSION@/$v/" "$here/fake/$b" > "$d/$b"
		chmod 755 "$d/$b"
	done
	tar -czf "$work/pkgs/tailscale_${v}_$arch.tgz" -C "$work/build" "tailscale_${v}_$arch"
	sha256sum "$work/pkgs/tailscale_${v}_$arch.tgz" | awk '{print $1}'
}
sum1=$(fake 9.9.1)
sum2=$(fake 9.9.2)
sum3=$(fake 9.9.3)

python3 -I "$here/serve.py" "$port" "$work/pkgs" &
srv_pid=$!
for _ in $(seq 1 20); do curl -fsS "http://127.0.0.1:$port/__state" >/dev/null 2>&1 && break; sleep 0.5; done
curl -fsS "http://127.0.0.1:$port/__state" >/dev/null || { echo "the stand-in server did not start" >&2; exit 1; }
posts() { curl -fsS "http://127.0.0.1:$port/__state" | python3 -I -c "import json,sys; s=json.load(sys.stdin); print($1)"; }

# ── the box ────────────────────────────────────────────────────────────────
docker build -q -t infra-alpine-sim "$here/host" >/dev/null || { echo "image build failed" >&2; exit 1; }
ssh-keygen -q -t ed25519 -N '' -f "$work/id"
# The host checkout's origin: this checkout's commit as `main`, so the plays' pull and
# commit check see the same commit the control node reviews.
git init -q --bare "$work/origin.git"
git -C "$repo" push -q "$work/origin.git" HEAD:refs/heads/main || { echo "could not seed the origin" >&2; exit 1; }
docker run -d --name "$box" --hostname zero --privileged \
	--add-host host.docker.internal:host-gateway -p 127.0.0.1:2222:22 \
	-v "$work/origin.git:/srv/origin.git:ro" infra-alpine-sim >/dev/null || exit 1
docker cp "$work/id.pub" "$box:/home/gavin/.ssh/authorized_keys"
on 'chown gavin:gavin /home/gavin/.ssh/authorized_keys; chmod 600 /home/gavin/.ssh/authorized_keys'
on 'su gavin -c "git clone -q -b main /srv/origin.git /home/gavin/infra"' || { echo "could not clone the host checkout" >&2; exit 1; }
on 'mkdir -p /etc/fake-tailscale' && printf '%s\n' "$good_key" | docker exec -i "$box" sh -c 'cat > /etc/fake-tailscale/expect-key'
for _ in $(seq 1 30); do
	ssh -q -i "$work/id" -p 2222 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null gavin@127.0.0.1 true && break
	sleep 1
done
on 'cat /etc/resolv.conf' > "$work/resolv.orig"

cat > "$repo/ansible/inventory.sim" <<INV
[fleet]
zero ansible_host=127.0.0.1 ansible_port=2222 ansible_user=gavin ansible_ssh_private_key_file=$work/id ansible_ssh_common_args='-o UserKnownHostsFile=/dev/null'
# The same box under another name, which tracks no tailscaled and no backup.
two ansible_host=127.0.0.1 ansible_port=2222 ansible_user=gavin ansible_ssh_private_key_file=$work/id ansible_ssh_common_args='-o UserKnownHostsFile=/dev/null'
# The runner, which is Ubuntu: a host that is not Alpine.
one ansible_connection=local

[control]
localhost ansible_connection=local
INV

cd "$repo/ansible" || exit 1
export ANSIBLE_CONFIG="$repo/ansible/ansible.cfg" ANSIBLE_HOST_KEY_CHECKING=False

leaks() {
	local log=$1 s
	for s in "$bad_key" "$good_key" "$ntfy_secret"; do
		grep -qF "$s" "$log" && fail "a secret ($s) appeared in $2"
	done
	if on 'test -f /root/.ssh/restore' 2>/dev/null; then
		grep -qF "$(on 'sed -n 2p /root/.ssh/restore')" "$log" && fail "the private restore key appeared in $2"
	fi
	return 0
}
play() {
	local book=$1
	shift
	ansible-playbook -i inventory.sim "playbooks/$book" "$@" > play.log 2>&1
	local rc=$?
	leaks play.log "the play's output"
	tail -n 30 play.log | sed 's/^/    | /'
	return $rc
}
# The same with the default callback at -vv, as a transcript to diagnose from is made
# (ansible.cfg), so a result printed in full is searched too.
play_verbose() {
	local book=$1
	shift
	ANSIBLE_STDOUT_CALLBACK=default ansible-playbook -vv -i inventory.sim "playbooks/$book" "$@" > play-verbose.log 2>&1
	local rc=$?
	leaks play-verbose.log "a -vv transcript"
	cp play-verbose.log play.log
	tail -n 30 play.log | sed 's/^/    | /'
	rm -f play-verbose.log
	return $rc
}
# The repo's callback wraps a long message onto lines marked ↪; says() unwraps them.
says() {
	python3 -I -c 'import re, sys; print(re.sub(r"\s+", " ", open(sys.argv[1]).read().replace("↪", " ")))' play.log \
		| grep -qF "$1"
}
ts() { play server-install-tailscale.yml -e target=zero "$@"; }
fakepin() { echo "-e tailscale_pkgs=$srv/stable -e tailscale_static_version=$1 -e $sha_key=$2"; }
# The first line's version number, as the play reads it.
ver() { on "$1 2>/dev/null | head -n 1 | grep -oE '^[0-9]+\\.[0-9]+\\.[0-9]+'"; }
svpid() { on 'cat /run/tailscaled.pid 2>/dev/null'; }
uplines() { on 'wc -l < /var/lib/fake-tailscale/up.log 2>/dev/null || echo 0' | tr -d ' '; }
resolv_same() { [ "$(on 'cat /etc/resolv.conf')" = "$(cat "$work/resolv.orig")" ]; }
nothing_installed() { on 'test ! -e /usr/local/sbin/tailscaled && test ! -e /etc/init.d/tailscaled'; }

# ════ server-install-tailscale.yml ═══════════════════════════════════════════
echo "== refusals: no target, not Alpine, no tracked service, Alpine's own tailscale"
if play server-install-tailscale.yml -e tailscale_auth_key=; then fail "ran with no -e target"; else
	says 'Name the host, -e target=' && pass "refused without -e target" || fail "no -e target failed, but not by its own check"
fi
if play server-install-tailscale.yml -e target=one -e tailscale_auth_key=; then fail "ran on a host that is not Alpine"; else
	says 'one is not Alpine' && pass "refused a host that is not Alpine" || fail "a host that is not Alpine failed, but not by its check"
fi
if play server-install-tailscale.yml -e target=two -e tailscale_auth_key=; then fail "ran on a host with no tracked tailscaled"; else
	says 'hosts/two/system/tailscaled is not in this checkout' && pass "refused a host with no tracked tailscaled" || fail "two failed, but not by the tracked-file check"
fi
if on 'apk add -q tailscale >/dev/null'; then
	if ts -e tailscale_auth_key=; then fail "ran beside Alpine's tailscale"; else
		says "Alpine's own tailscale package is installed" && pass "refused while Alpine's tailscale is installed" || fail "Alpine's tailscale failed, but not by its check"
	fi
	on 'apk del -q tailscale >/dev/null'
else
	fail "could not install Alpine's tailscale to test the refusal"
fi
nothing_installed && pass "the refusals installed nothing" || fail "a refusal installed something"

echo "== --check on a box with nothing"
if ts --check -e tailscale_auth_key=; then pass "dry run exits 0"; else fail "dry run failed"; fi
says 'DRY RUN: nothing was downloaded' && says 'would join' && pass "dry run reports what it would do" || fail "dry run report missing"
nothing_installed && on 'test ! -e /etc/runlevels/default/tailscaled' && pass "dry run installed and enabled nothing" || fail "dry run changed the box"

echo "== the real pin, with a key Tailscale refuses"
if ts -e "tailscale_auth_key=$bad_key"; then fail "joined with a key that is not real"; else pass "stopped at the join"; fi
says 'Join the tailnet as tag:fleet, keeping DNS' && pass "the failure is the join" || fail "it failed before the join"
# A flag Tailscale did not know, or a key file it could not read, would fail differently:
# this is its control server refusing the key it read from the file.
says 'backend error: invalid key' && pass "the real tailscale read the key file and Tailscale refused the key" || fail "the real tailscale did not get as far as refusing the key"
# The two settings the play checks after a join, by the names it reads them by.
prefs=$(on '/usr/local/bin/tailscale debug prefs')
if printf '%s' "$prefs" | python3 -I -c 'import json,sys; p=json.load(sys.stdin); print("    CorpDNS", p["CorpDNS"], "AdvertiseTags", p["AdvertiseTags"])'; then
	pass "the real tailscale's prefs carry CorpDNS and AdvertiseTags"
else
	fail "the real tailscale's prefs lack CorpDNS or AdvertiseTags"
fi
[ "$(ver '/usr/local/bin/tailscale version')" = "$pin_version" ] && pass "tailscale is $pin_version" || fail "tailscale is '$(ver '/usr/local/bin/tailscale version')'"
[ "$(ver '/usr/local/sbin/tailscaled --version')" = "$pin_version" ] && pass "tailscaled reports $pin_version" || fail "tailscaled reports '$(ver '/usr/local/sbin/tailscaled --version')'"
[ "$(on 'stat -c "%U %a" /usr/local/sbin/tailscaled /usr/local/bin/tailscale' | sort -u)" = "root 755" ] && pass "both binaries root 0755" || fail "binary modes wrong"
on 'cat /etc/init.d/tailscaled' | cmp -s - "$repo/hosts/zero/system/tailscaled" && pass "the service is the tracked file" || fail "the service differs from the tracked file"
on 'test -L /etc/runlevels/default/tailscaled' && pass "tailscaled is in the default runlevel" || fail "tailscaled is not in the default runlevel"
on 'rc-service tailscaled status' | grep -q started && pass "tailscaled started" || fail "tailscaled is not started"
on 'test -e /run/infra-tailscale-key' && fail "the auth key file was left in /run" || pass "the auth key file is gone after a failed join"
on 'test ! -e /var/tmp/infra-tailscale.tgz && test ! -e /var/tmp/infra-tailscale' && pass "the download is removed" || fail "the download was left"
resolv_same && pass "resolv.conf unchanged" || fail "resolv.conf changed"

echo "== --check at the pin"
if ts --check -e tailscale_auth_key=; then pass "dry run exits 0"; else fail "dry run failed"; fi
says 'already at the pin' && pass "reports the binaries at the pin" || fail "did not report the binaries at the pin"
says "running $pin_version" && pass "read the real daemon's running version, $pin_version" || fail "did not read the real daemon's running version"

echo "== a stand-in 9.9.1, joining (a -vv transcript, searched for secrets)"
pid0=$(svpid)
# shellcheck disable=SC2046  # fakepin is a list of options
if play_verbose server-install-tailscale.yml -e target=zero $(fakepin 9.9.1 "$sum1") -e "tailscale_auth_key=$good_key"; then pass "exits 0"; else fail "failed"; fi
[ "$(ver '/usr/local/bin/tailscale version')" = 9.9.1 ] && pass "tailscale moved to 9.9.1" || fail "tailscale is '$(ver '/usr/local/bin/tailscale version')'"
[ "$(ver '/usr/local/bin/tailscale.previous version')" = "$pin_version" ] && [ "$(ver '/usr/local/sbin/tailscaled.previous --version')" = "$pin_version" ] \
	&& pass "the $pin_version binaries kept as .previous" || fail ".previous does not hold $pin_version"
[ -n "$pid0" ] && [ "$(svpid)" != "$pid0" ] && pass "tailscaled restarted for the moved binary" || fail "tailscaled was not restarted"
[ "$(uplines)" = 1 ] && pass "tailscale up ran once" || fail "tailscale up ran $(uplines) times"
up=$(on 'cat /var/lib/fake-tailscale/up.log')
case "$up" in *--advertise-tags=tag:fleet*--accept-dns=false*) pass "up had --advertise-tags=tag:fleet --accept-dns=false" ;; *) fail "up's flags: $up" ;; esac
case "$up" in *"--auth-key=file:/run/infra-tailscale-key "*) pass "the key went by file, in /run" ;; *) fail "the key did not go by a file in /run: $up" ;; esac
case "$up" in *"$good_key"*) fail "the key was in up's argv" ;; *) pass "the key was not in up's argv" ;; esac
[ "$(on 'cat /var/lib/fake-tailscale/keyfile-mode')" = "root 600" ] && pass "the key file was root 0600" || fail "the key file was $(on 'cat /var/lib/fake-tailscale/keyfile-mode')"
on 'test ! -e "$(cat /var/lib/fake-tailscale/keyfile-path)"' && pass "the key file is gone" || fail "the key file was left"
grep -q 'joined now' play.log && grep -q '100.101.102.103' play.log && grep -q 'zero.tail-sim.ts.net' play.log \
	&& pass "printed joined, the address and the name" || fail "did not print the join, address and name"
resolv_same && pass "resolv.conf unchanged" || fail "resolv.conf changed"

echo "== a re-run at 9.9.1, with a key file a killed run left"
on 'echo leftover > /run/infra-tailscale-key'
pid1=$(svpid)
# shellcheck disable=SC2046
if ts $(fakepin 9.9.1 "$sum1") -e tailscale_auth_key=; then pass "exits 0"; else fail "failed"; fi
[ "$(svpid)" = "$pid1" ] && pass "tailscaled was not restarted" || fail "tailscaled restarted with nothing moved"
[ "$(uplines)" = 1 ] && pass "no second join" || fail "joined again"
says 'already at the pin' && says 'already joined' && pass "reports nothing to do" || fail "re-run report wrong"
# Calibration for the tailnet case below: a connection that is not over the tailnet must
# be read, and read as not.
grep -o 'This run came in from [^,]*' play.log | sed 's/^/    /'
says 'This run came in from 172.' && says 'not over the tailnet' && pass "read this connection's address, not the tailnet's" || fail "did not read this connection's address"
on 'test ! -e /run/infra-tailscale-key' && pass "swept the leftover key file" || fail "left the leftover key file"

echo "== the pin moved to 9.9.2"
# shellcheck disable=SC2046
if ts $(fakepin 9.9.2 "$sum2") -e tailscale_auth_key=; then pass "exits 0"; else fail "failed"; fi
[ "$(ver '/usr/local/bin/tailscale version')" = 9.9.2 ] && [ "$(ver '/usr/local/bin/tailscale.previous version')" = 9.9.1 ] \
	&& pass "9.9.2 installed, 9.9.1 kept as previous" || fail "the move to 9.9.2 is wrong"
[ "$(svpid)" != "$pid1" ] && pass "tailscaled restarted" || fail "tailscaled was not restarted"
[ "$(uplines)" = 1 ] && pass "no second join" || fail "joined again"

echo "== the binaries at the pin, the daemon still running the previous"
# As a run that died between install and restart leaves it: 9.9.1 running, 9.9.2 on disk.
# Renamed into place, never copied over, since the running daemon is a script sh reads.
on 'cd /usr/local && cp -p sbin/tailscaled /tmp/td && cp -p bin/tailscale /tmp/t && cp -p sbin/tailscaled.previous sbin/td.new && mv -f sbin/td.new sbin/tailscaled && cp -p bin/tailscale.previous bin/t.new && mv -f bin/t.new bin/tailscale && rc-service tailscaled restart >/dev/null 2>&1 && mv -f /tmp/td sbin/tailscaled && mv -f /tmp/t bin/tailscale'
[ "$(on 'cat /run/fake-tailscaled.version')" = 9.9.1-tsim ] && [ "$(ver '/usr/local/bin/tailscale version')" = 9.9.2 ] \
	&& pass "set up: 9.9.1 running, 9.9.2 on disk" || fail "could not set up a stale daemon"
pids=$(svpid)
# shellcheck disable=SC2046
if ts $(fakepin 9.9.2 "$sum2") -e tailscale_auth_key=; then pass "exits 0"; else fail "failed"; fi
says 'running 9.9.1' && [ "$(svpid)" != "$pids" ] && [ "$(on 'cat /run/fake-tailscaled.version')" = 9.9.2-tsim ] \
	&& pass "restarted the stale daemon onto the pin" || fail "did not restart the stale daemon"
[ "$(ver '/usr/local/bin/tailscale.previous version')" = 9.9.1 ] && pass ".previous untouched, nothing downloaded" || fail ".previous changed"

echo "== a restart wanted, over the tailnet"
# A second network in the tailnet's range: the runner reaches the box from 100.64.77.1,
# which the play must read as a connection over the tailnet.
if docker network create --subnet 100.64.77.0/24 infra-sim-tailnet >/dev/null && docker network connect --ip 100.64.77.2 infra-sim-tailnet "$box"; then
	pidt=$(svpid)
	# shellcheck disable=SC2046
	if ts $(fakepin 9.9.3 "$sum3") -e tailscale_auth_key= -e ansible_host=100.64.77.2 -e ansible_port=22; then fail "restarted over the tailnet"; else
		says 'over the tailnet (100.64.77.1)' && pass "refused to restart over the tailnet" || fail "failed, but not by the tailnet check"
	fi
	grep -o 'This run came in from [^,]*' play.log | sed 's/^/    /'
	[ "$(ver '/usr/local/bin/tailscale version')" = 9.9.2 ] && [ "$(svpid)" = "$pidt" ] && pass "binaries and tailscaled untouched" || fail "the box changed"
	docker network disconnect infra-sim-tailnet "$box"
else
	fail "could not make a network in the tailnet's range"
fi

echo "== a pin whose SHA-256 is wrong"
pid2=$(svpid)
t0=$(date +%s)
# shellcheck disable=SC2046
if ts $(fakepin 9.9.3 "$sum2") -e tailscale_auth_key=; then fail "installed a tarball that fails its checksum"; else pass "stopped"; fi
# Retries are 15 s apart, so a run that retried a mismatch takes 45 s more.
[ $(($(date +%s) - t0)) -lt 40 ] && says 'checksum' && pass "stopped at the first mismatch, without retrying" || fail "took $(($(date +%s) - t0)) s: it retried the mismatch, or failed otherwise"
[ "$(ver '/usr/local/bin/tailscale version')" = 9.9.2 ] && [ "$(svpid)" = "$pid2" ] && pass "binaries and tailscaled untouched" || fail "the box changed"
on 'test ! -e /var/tmp/infra-tailscale.tgz' && pass "no download left" || fail "the bad download was left"

echo "== off the tailnet, with no key, then with one"
on 'echo NeedsLogin > /var/lib/fake-tailscale/state'
# shellcheck disable=SC2046
if ts $(fakepin 9.9.2 "$sum2") -e tailscale_auth_key=; then fail "ran on with no key"; else
	says 'no auth key was given' && pass "refused to go on without a key" || fail "failed, but not by the key check"
fi
[ "$(uplines)" = 1 ] && pass "no join attempted" || fail "a join was attempted"
# shellcheck disable=SC2046
if ts $(fakepin 9.9.2 "$sum2") -e "tailscale_auth_key=$good_key"; then pass "joined again with a key"; else fail "did not join with a key"; fi

echo "== a join that takes over resolv.conf"
on 'echo NeedsLogin > /var/lib/fake-tailscale/state; touch /etc/fake-tailscale/clobber-dns'
# shellcheck disable=SC2046
if ts $(fakepin 9.9.2 "$sum2") -e "tailscale_auth_key=$good_key"; then fail "passed with resolv.conf changed"; else
	says 'resolv.conf CHANGED' && pass "caught the changed resolv.conf" || fail "failed, but not by the resolv.conf check"
fi
on 'rm -f /etc/fake-tailscale/clobber-dns' && docker exec -i "$box" sh -c 'cat > /etc/resolv.conf' < "$work/resolv.orig"

# ════ server-create-restore-key.yml ══════════════════════════════════════════
echo "== the restore key: refusals"
on 'echo NeedsLogin > /var/lib/fake-tailscale/state'
if play server-create-restore-key.yml -e target=zero; then fail "made a key off the tailnet"; else
	says 'zero is not on the tailnet' && pass "refused off the tailnet" || fail "failed, but not by the tailnet check"
fi
on 'echo Running > /var/lib/fake-tailscale/state'
if play server-create-restore-key.yml -e target=two; then fail "made a key for a host three does not pull"; else
	says 'hosts/two/system/rsyncd-backup.conf is not in this checkout' && pass "refused a host three does not pull" || fail "two failed, but not by its check"
fi
on 'test ! -e /root/.ssh/restore' && pass "no key made by a refusal" || fail "a refusal made a key"

echo "== the restore key: --check, a real run, a re-run"
if play server-create-restore-key.yml -e target=zero --check; then pass "dry run exits 0"; else fail "dry run failed"; fi
says 'would be made' && on 'test ! -e /root/.ssh/restore' && pass "dry run made nothing and said so" || fail "dry run wrong"
if play server-create-restore-key.yml -e target=zero; then pass "real run exits 0"; else fail "real run failed"; fi
[ "$(on 'stat -c "%U %a" /root/.ssh /root/.ssh/restore' | tr '\n' ' ')" = "root 700 root 600 " ] && pass "/root/.ssh 0700, the key 0600, root's" || fail "modes: $(on 'stat -c "%n %U %a" /root/.ssh /root/.ssh/restore')"
pub=$(on 'cat /root/.ssh/restore.pub')
case "$pub" in "ssh-ed25519 "*" zero restore") pass "ed25519, comment 'zero restore'" ;; *) fail "the public key is '$pub'" ;; esac
fp=$(on 'ssh-keygen -lf /root/.ssh/restore.pub' | cut -d' ' -f2)
hostkey=$(on 'cut -d" " -f1,2 /etc/ssh/ssh_host_ed25519_key.pub')
hostfp=$(on 'ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub' | cut -d' ' -f2)
says "key: $pub" && says 'address: 100.101.102.103' && says "host key: $hostkey" &&
	says "fingerprints: $fp for the key, $hostfp for the host key" &&
	pass "printed the key, the address, the host key and both fingerprints" || fail "did not print the key, address, host key and fingerprints"
keysum=$(on 'sha256sum /root/.ssh/restore')
if play server-create-restore-key.yml -e target=zero; then pass "re-run exits 0"; else fail "re-run failed"; fi
[ "$(on 'sha256sum /root/.ssh/restore')" = "$keysum" ] && says 'Already there, not touched' && pass "the key was not replaced" || fail "the key was replaced"

# ════ server-store-backup-ntfy-url.yml ═══════════════════════════════════════
url="$srv/$ntfy_secret"
ntfy() { play server-store-backup-ntfy-url.yml -e target=zero "$@"; }
echo "== the ntfy URL: refusals and --check"
if ntfy -e '{"ntfy_url": "not a url"}' -e ntfy_test=n; then fail "stored something that is not a URL"; else
	says 'is not a URL with a topic' && pass "refused a value that is not a URL" || fail "failed, but not by the URL check"
fi
if ntfy -e "ntfy_url=$url" -e ntfy_test=y --check; then pass "dry run exits 0"; else fail "dry run failed"; fi
on 'test ! -e /var/lib/backup-alert/ntfy-url' && [ "$(posts 'len(s["posts"])')" = 0 ] && pass "dry run wrote and sent nothing" || fail "dry run wrote or sent"

echo "== the ntfy URL: stored and tested (a -vv transcript, searched for the URL)"
if play_verbose server-store-backup-ntfy-url.yml -e target=zero -e "ntfy_url=$url" -e ntfy_test=y; then pass "exits 0"; else fail "failed"; fi
[ "$(on 'cat /var/lib/backup-alert/ntfy-url')" = "$url" ] && pass "the file holds the URL" || fail "the file does not hold the URL"
[ "$(on 'stat -c "%U %a" /var/lib/backup-alert /var/lib/backup-alert/ntfy-url' | tr '\n' ' ')" = "root 700 root 600 " ] && pass "directory 0700, file 0600, root's" || fail "modes wrong"
[ "$(posts 'len(s["posts"])')" = 1 ] && [ "$(posts 's["posts"][0]["path"]')" = "/$ntfy_secret" ] && pass "one test message reached the topic" || fail "posts: $(posts 'len(s["posts"])')"
grep -q 'HTTP 200' play.log && pass "printed the status" || fail "did not print the status"
if ntfy -e "ntfy_url=$url" -e ntfy_test=n; then pass "re-run exits 0"; else fail "re-run failed"; fi
says 'already held this URL, unchanged' && [ "$(posts 'len(s["posts"])')" = 1 ] && pass "re-run changed and sent nothing" || fail "re-run wrong"

echo "== the ntfy URL: a topic that refuses the test"
curl -fsS -X POST -d '{"ntfy_status": 403}' "http://127.0.0.1:$port/__control" >/dev/null
if ntfy -e "ntfy_url=$url-2" -e ntfy_test=yes; then fail "passed a refused test message"; else
	says 'HTTP 403' && pass "stopped on the refusal and printed its status" || fail "failed, but not on the status"
fi
[ "$(on 'cat /var/lib/backup-alert/ntfy-url')" = "$url-2" ] && pass "the new URL is stored anyway" || fail "the new URL was not stored"

# ════ server-install-system-files.yml ════════════════════════════════════════
# Which files the play reads for each host, and that it reads them from the tool on the box.
# Only --check: the real run's writes are install-system-file's own, unchanged here.
# zero's expected list is the one the play found before it asked the tool (a find over
# hosts/zero/system/ less the docs and hw-inventory.toml), so a green run shows it unchanged.
sf() { play server-install-system-files.yml --check "$@"; }
zero_files=$(find "$repo/hosts/zero/system" -maxdepth 1 -type f ! -name README.md ! -name hardware.md ! -name hw-inventory.toml -printf '%f\n' | sort | tr '\n' ' ')
zero_n=$(echo "$zero_files" | wc -w)
echo "== the tracked system files: zero's, from the box's own tool"
listed=$(on 'su gavin -c "cd /home/gavin/infra && bin/install-system-file --list"' | sed 's|.*/||' | sort | tr '\n' ' ')
[ "$listed" = "$zero_files" ] && pass "install-system-file --list on zero names hosts/zero/system/'s files" || fail "--list on zero: '$listed', want '$zero_files'"
if sf -l zero; then pass "dry run exits 0"; else fail "dry run failed"; fi
says "$zero_n of $zero_n under hosts/zero/system: ${zero_files% }" && pass "the play read the same $zero_n files" || fail "the play read another list for zero"
# backup-age-check is tracked but not to be installed, so its header says init none.
# The callback prints each refused file's name under the task, one `~ <name>` line each.
awk '/Print each file the dry run refused to install/ { r = 1; next } r && !/~ / { r = 0 } r' play.log | grep -q '~ backup-age-check$' &&
	pass "the dry run refused backup-age-check, by its init none" || fail "the dry run did not refuse backup-age-check"
if sf -l zero -e only=sshd-infra.conf; then pass "-e only exits 0"; else fail "-e only failed"; fi
says "1 of $zero_n under hosts/zero/system: sshd-infra.conf" && pass "-e only narrowed it to one file" || fail "-e only did not narrow the list"
on 'test ! -e /etc/init.d/bcache-register && test ! -e /etc/cloudflared/config.yml' && pass "the dry runs installed nothing" || fail "a dry run installed something"
if sf -l two; then fail "ran for an inventory name that is not the box's hostname"; else
	says "two's install-system-file lists hosts/zero/system, which is not two's" && pass "refused a box whose hostname is not its inventory name" || fail "two failed, but not by the hostname check"
fi

# The same box answering as three, whose leap/MOVED sends the tool to leap/system/: the
# command the owner had to replace by hand on 2026-11-18. The box runs OpenRC, so the tool
# must then refuse three's systemd file, by its own init check.
echo "== the tracked system files: three's, by its leap/MOVED"
on 'hostname three && echo "127.0.0.1 three" >> /etc/hosts'
sed -i 's/^two /three /' "$repo/ansible/inventory.sim"
listed=$(on 'su gavin -c "cd /home/gavin/infra && bin/install-system-file --list"' | sed 's|/[^/]*$||' | sort -u)
[ "$listed" = "hosts/three/leap/system" ] && pass "install-system-file --list on three reads hosts/three/leap/system" || fail "--list on three read '$listed'"
three_n=$(find "$repo/hosts/three/leap/system" -maxdepth 1 -type f ! -name '*.md' | wc -l)
if sf -l three -e only=cloudflared-config.yml; then pass "dry run exits 0"; else fail "dry run failed"; fi
says "1 of $three_n under hosts/three/leap/system: cloudflared-config.yml" && pass "the play read leap/system/ for three" || fail "the play did not read leap/system/ for three"
# The repo's callback prints a looped debug's label and not its message, so the play's log
# names the refused file only; the reason is read from the tool itself, as the play runs it.
grep -A1 'Print each file the dry run refused to install' play.log | grep -q '~ cloudflared-config.yml' && pass "the play counted cloudflared-config.yml as refused" || fail "the play did not count three's file as refused"
said=$(on 'su gavin -c "cd /home/gavin/infra && bin/install-system-file cloudflared-config.yml --new --allow-content-change"' 2>&1)
case "$said" in *'declares init=systemd but this host runs openrc'*) pass "the tool refused a systemd file on an OpenRC box" ;; *) fail "the tool did not refuse three's file on OpenRC: $said" ;; esac
on 'test ! -e /etc/cloudflared/config.yml' && pass "installed nothing" || fail "installed three's file"
on 'hostname zero'

# ════ zero's snapper, installed as hosts/zero/system/README.md gives it ══════
# On zero's own release and architecture: Alpine 3.24, arm64. The file comes from edge/testing
# by its full name, is checked against the SHA-256 in the README, and apk checks its
# signature against Alpine's keys. The README's sha256sum line is read out and run as it is.
echo "== zero's snapper: the pinned .apk from edge/testing"
readme="$repo/hosts/zero/system/README.md"
apk_url=$(grep -oE 'https://dl-cdn\.alpinelinux\.org/alpine/edge/testing/aarch64/snapper-[^ ]+\.apk' "$readme" | head -n 1)
sha_line=$(grep -oE "echo '[0-9a-f]{64}  snapper-[^']+\.apk' \| sha256sum -c -" "$readme" | head -n 1)
if [ -z "$apk_url" ] || [ -z "$sha_line" ]; then
	fail "the README gives no snapper URL or no sha256sum line"
else
	on "cd /root && wget -q '$apk_url'" && pass "downloaded ${apk_url##*/}" || fail "could not download $apk_url"
	out=$(on "cd /root && $sha_line" 2>&1); echo "    $out"
	case "$out" in *': OK') pass "its SHA-256 is the README's" ;; *) fail "its SHA-256 is not the README's" ;; esac
	# The way it would fail with a bad signature: apk refuses a file whose signature no
	# key in /etc/apk/keys made, unless told --allow-untrusted, which the README never is.
	on "cd /root && cp '${apk_url##*/}' bad.apk && dd if=/dev/urandom of=bad.apk bs=1 count=64 seek=200000 conv=notrunc 2>/dev/null && ! apk add --quiet ./bad.apk" >/dev/null 2>&1 &&
		pass "apk refuses a changed copy of it" || fail "apk installed a changed copy"
	on 'rm -f /root/bad.apk'
	if out=$(on "cd /root && apk add --quiet './${apk_url##*/}' && apk add --quiet 'snapper=0.13.1-r0' && snapper --version" 2>&1); then
		pass "apk installed it, with its dependencies from Alpine 3.24's own repositories: $(echo "$out" | head -n 1)"
	else
		fail "apk could not install it: $(echo "$out" | tail -n 3 | tr '\n' ' ')"
	fi
	echo "    world: $(on 'grep "^snapper" /etc/apk/world' 2>&1)"
	on 'grep -qx "snapper=0.13.1-r0" /etc/apk/world' && pass "apk's world pins snapper=0.13.1-r0" || fail "apk's world does not pin snapper"
	on 'apk upgrade --simulate 2>&1 | grep -qE "(Upgrading|Downgrading|Purging|Replacing) snapper"' && fail "apk upgrade would move snapper" || pass "apk upgrade leaves snapper alone"
	on 'rc-update show | grep -qw dbus' && fail "a dependency put dbus in a runlevel" || pass "no runlevel starts dbus, though apk installed it"
	on 'snapper --no-dbus list-configs' >/dev/null 2>&1 && pass "snapper answers with --no-dbus" || fail "snapper --no-dbus does not answer"
	on 'sh -n /etc/periodic/hourly/snapper && . /etc/snapper/snapper && [ -z "$SNAPPER_CONFIGS" ]' && pass "the package's hourly script reads an empty SNAPPER_CONFIGS" || fail "SNAPPER_CONFIGS is not empty"
	on '/bin/setpriv --version 2>&1 | grep -q util-linux' && fail "util-linux setpriv was already there" || pass "before apk add setpriv, /bin/setpriv is not util-linux's"
	on 'apk add --quiet setpriv && /bin/setpriv --version' 2>&1 | grep -q util-linux && pass "apk add setpriv gives util-linux's /bin/setpriv" || fail "/bin/setpriv is not util-linux's after apk add setpriv"
fi

# ════ install-system-file's sudoers check ════════════════════════════════════
# Calibrated first on a sudoers file that works, then the repo copy, then a broken copy,
# which must be refused before anything is written.
echo "== install-system-file: sudoers is checked by visudo before it is written"
on 'sudo visudo -cf /etc/sudoers.d/gavin' 2>&1 | grep -q 'parsed OK' && pass "visudo reads the box's own sudoers.d/gavin as parsed OK" || fail "visudo does not pass the box's own sudoers file"
said=$(on 'su gavin -c "cd /home/gavin/infra && bin/install-system-file sudoers-backup --new"' 2>&1)
case "$said" in *'pre-checks on the repo copy: ok'*'DRY RUN'*) pass "sudoers-backup passes the pre-check" ;; *) fail "sudoers-backup did not pass: $(echo "$said" | tail -n 3 | tr '\n' ' ')" ;; esac
on "su gavin -c 'cd /home/gavin/infra && sed -i \"s/NOPASSWD:/NOPASSWD/\" hosts/zero/system/sudoers-backup'"
said=$(on 'su gavin -c "cd /home/gavin/infra && bin/install-system-file sudoers-backup --new --commit"' 2>&1)
case "$said" in *'fails validate_sudoers'*) pass "a broken copy is refused by visudo" ;; *) fail "a broken copy was not refused: $(echo "$said" | tail -n 3 | tr '\n' ' ')" ;; esac
on 'test ! -e /etc/sudoers.d/backup && sudo true' && pass "nothing was written, and sudo still works" || fail "a broken sudoers file was written"
on 'su gavin -c "cd /home/gavin/infra && git checkout -q hosts/zero/system/sudoers-backup"'

# ════ server-start-dev-containers.yml ════════════════════════════════════════
# The box has no Docker, so the real dev/Makefile is run only to its first guard, which
# must refuse for want of dev/.env; a stand-in checkout's Makefile, whose `up` prints who ran
# it and where, shows make runs as root in dev/ and its output prints. `two` is pointed at a
# checkout with no dev/, which must be refused.
echo "== the dev containers play: refusals, --check, the real Makefile's guard, a stand-in's up"
on 'apk add --quiet make' || fail "could not install make in the box"
if play server-start-dev-containers.yml -e target=nowhere; then fail "ran against a host not in the fleet"; else
	says 'is not in the inventory' && pass "refused a target outside the fleet" || fail "a stray target failed, but not by its check"
fi
if play server-start-dev-containers.yml -e target=two -e infra_checkout=/nonexistent; then fail "ran on a host with no dev/"; else
	says '/nonexistent/dev/Makefile is not on two' && pass "refused a host with no dev/Makefile" || fail "two failed, but not by its check"
fi
if play server-start-dev-containers.yml --check; then pass "--check exits 0, target zero by default"; else fail "--check failed"; fi
says 'DRY RUN: would run make up in /home/gavin/infra/dev as root' && pass "--check says what it would run" || fail "--check did not say what it would run"
if play server-start-dev-containers.yml; then fail "the real dev/Makefile's up succeeded with no .env"; else
	says 'no /home/gavin/infra/dev/.env' && says 'make up exited 2' && pass "the real dev/Makefile ran as far as its .env guard, and its refusal printed and failed the play" ||
		fail "the real dev/Makefile failed, but not at its .env guard"
fi
on 'mkdir -p /srv/fakeinfra/dev && printf "up:\n\t@echo \"make up as uid \$\$(id -u) in \$\$(pwd)\"\n" > /srv/fakeinfra/dev/Makefile'
if play server-start-dev-containers.yml -e infra_checkout=/srv/fakeinfra; then pass "a stand-in's make up succeeds"; else fail "a stand-in's make up failed"; fi
says 'make up as uid 0 in /srv/fakeinfra/dev' && pass "make ran as root in dev/, and its output printed" || fail "make's output does not show root in dev/"

# ════ server-unlock-arrays.yml ═══════════════════════════════════════════════
# The full unlock is microos-sim.yml's, on Leap. Here: the box's OpenRC, which the play has
# no branch for and must refuse without asking; and the runner, `one`, whose systemd it
# does: a LUKS volume on a loop device with crypttab and fstab lines, a wrong passphrase, a
# right one at -vv through the default callback, and the units stopped as the lock command
# stops them. play-prompts.py types at the play's prompts in a terminal, as the owner does.
echo "== the unlock play: OpenRC refused; the runner's systemd unlocks"
run_pw=sim-unlock-$(openssl rand -hex 8)
unlock() { # <answers as JSON> [ansible-playbook argument]...
	local answers=$1 rc
	shift
	SIM_ANSWERS=$answers python3 -I "$here/../microos/host/play-prompts.py" \
		ansible-playbook -i inventory.sim playbooks/server-unlock-arrays.yml "$@" > play.log 2>&1
	rc=$?
	grep -qF "$run_pw" play.log && fail "the passphrase appeared in the unlock play's output"
	leaks play.log "the unlock play's output"
	tail -n 30 play.log | sed 's/^/    | /'
	return $rc
}
vols='{"unlock_volumes": [{"name": "simrun", "mount": "/mnt/simrun"}]}'
if unlock '{}' -l zero -e "$vols"; then fail "the play passed on OpenRC"; else
	says 'zero simrun: failed: this play unlocks on systemd only so far' && pass "OpenRC is refused, by name" || fail "zero failed, but not as OpenRC"
fi
grep -q '^prompted: ' play.log && fail "the play asked on OpenRC" || pass "nothing was asked on OpenRC"
if unlock '{}' -l one -e "$vols"; then fail "the play passed with no crypttab line"; else
	says 'one simrun: failed: no systemd-cryptsetup@simrun.service: /etc/crypttab has no line for simrun' &&
		pass "a volume crypttab does not name is refused, unprivileged" || fail "no crypttab line, but not refused by it"
fi
sudo apt-get install -y -q --no-install-recommends cryptsetup-bin > /dev/null 2>&1
sudo apt-get install -y -q --no-install-recommends systemd-cryptsetup > /dev/null 2>&1
if [ ! -x /usr/lib/systemd/system-generators/systemd-cryptsetup-generator ]; then
	fail "the runner has no crypttab generator, so its systemd cannot be tried"
else
	sudo cp -a /etc/crypttab "$work/crypttab" 2> /dev/null || sudo touch "$work/crypttab.absent"
	sudo cp -a /etc/fstab "$work/fstab"
	truncate -s 64M "$work/simrun.img"
	loopdev=$(sudo losetup -f --show "$work/simrun.img")
	printf '%s' "$run_pw" | sudo cryptsetup luksFormat -q --type luks2 --pbkdf pbkdf2 --pbkdf-force-iterations 1000 --key-file=- "$loopdev"
	printf '%s' "$run_pw" | sudo cryptsetup open --key-file=- "$loopdev" simrun && sudo mkfs.ext4 -q /dev/mapper/simrun && sudo cryptsetup close simrun
	printf 'simrun %s none luks,noauto,password-cache=no\n' "$loopdev" | sudo tee -a /etc/crypttab > /dev/null
	echo '/dev/mapper/simrun /mnt/simrun ext4 noauto,nofail,nosuid,nodev 0 0' | sudo tee -a /etc/fstab > /dev/null
	sudo mkdir -p /mnt/simrun && sudo systemctl daemon-reload
	if unlock '{"simrun on one": "not-it"}' -l one -e "$vols"; then fail "a wrong passphrase passed"; else
		says 'one simrun: failed: wrong passphrase; still locked' && pass "a wrong passphrase is reported" || fail "a wrong passphrase was not reported as one"
	fi
	grep -qx 'prompted: simrun on one' play.log && pass "the locked volume was asked for, by volume and host" || fail "simrun was not asked for"
	[ ! -e /dev/mapper/simrun ] && [ "$(systemctl show -p ActiveState --value systemd-cryptsetup@simrun.service)" = inactive ] &&
		pass "it is left locked, its unit not failed" || fail "after a wrong passphrase: $(systemctl show -p ActiveState --value systemd-cryptsetup@simrun.service), $(ls /dev/mapper)"
	if ANSIBLE_STDOUT_CALLBACK=default unlock "{\"simrun on one\": \"$run_pw\"}" -l one -e "$vols" -vv; then
		pass "the right passphrase unlocks, at -vv, with no secret in the transcript"
	else
		fail "the right passphrase did not unlock"
	fi
	systemctl is-active --quiet systemd-cryptsetup@simrun.service && findmnt -no OPTIONS /mnt/simrun | grep -qw nosuid &&
		pass "systemd-cryptsetup@simrun.service is active and the volume mounted nosuid" || fail "not unlocked as after a manual unlock"
	if unlock '{}' -l one -e "$vols"; then pass "a re-run passes"; else fail "a re-run failed"; fi
	says 'one simrun: already open' && ! grep -q '^prompted: ' play.log && pass "an open volume is reported and not asked for" || fail "an open volume was asked for or misreported"
	sudo systemctl stop mnt-simrun.mount systemd-cryptsetup@simrun.service
	[ ! -e /dev/mapper/simrun ] && pass "stopping the mount and the unit locks it, as the README's lock does" || fail "stopping the units left it open"
	if [ -e "$work/crypttab.absent" ]; then sudo rm -f /etc/crypttab; else sudo cp -a "$work/crypttab" /etc/crypttab; fi
	sudo cp -a "$work/fstab" /etc/fstab && sudo losetup -d "$loopdev" && sudo systemctl daemon-reload
fi

echo
if [ "$fails" -gt 0 ]; then echo "$fails check(s) FAILED"; exit 1; fi
echo "all checks passed"
