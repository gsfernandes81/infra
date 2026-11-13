#!/bin/bash
# pass and fail always succeed, so `A && pass || fail` can never run both.
# shellcheck disable=SC2015
# Runs ansible/playbooks/server-create-fleet-ssh-access.yml against mock_api.py for `three`,
# a host with no system/ whose tunnel config is under leap/system/: the refusals, a dry run,
# a real run to the final message, a re-run, the undo, and a gate that never takes, which
# must be undone by the play's rescue. Also `one`, which has both directories, to show
# system/ wins there. Prints PASS or FAIL per check and exits 1 on any FAIL. CI runs it
# (.github/workflows/cloudflare-sim.yml).
#
# It writes nothing outside a temporary HOME except, in the repo, an inventory beside
# ansible.cfg and the stand-in configs below, all removed on exit. Three things are stood
# in for, and a green run says nothing about them: the edge (the probe URLs point at the
# stand-in), the ssh probe (`true`, since no host answers here), and the yes at the prompt
# (an extra var, which beats the registered answer; without a TTY the prompt does not wait).
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
port=8788
api="http://127.0.0.1:$port/client/v4"
probe="http://127.0.0.1:$port/__probe"
three_cfg="$repo/hosts/three/leap/system/cloudflared-config.yml"
fake="$repo/hosts/simleap"
fails=0

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
state() { curl -fsS "http://127.0.0.1:$port/__state"; }
control() { curl -fsS -X POST -H 'Content-Type: application/json' -d "$1" "http://127.0.0.1:$port/__control" >/dev/null; }
jq_state() { state | python3 -I -c "import json,sys; s=json.load(sys.stdin); print($1)"; }

if [ -e "$fake" ]; then
	echo "refusing: $fake already exists" >&2
	exit 1
fi
# three's real config, once committed, is used as it is; until then a stand-in in its shape
# (hosts/three/leap/README.md § After the first boot, step 3) is written and removed.
planted_three=
if [ ! -e "$three_cfg" ]; then
	planted_three=1
	cat > "$three_cfg" <<'CFG'
tunnel: 00000000-0000-0000-0000-000000000000
credentials-file: /etc/cloudflared/three.json
ingress:
  - hostname: ssh-three.gsrpi.uk
    service: ssh://127.0.0.1:22
  - hostname: syncthing-three.gsrpi.uk
    service: http://127.0.0.1:8384
  - service: http_status:404
CFG
fi
# A Leap-only host whose tracked routing sends its ssh hostname to the wrong port.
mkdir -p "$fake/leap/system"
cat > "$fake/leap/system/cloudflared-config.yml" <<'CFG'
ingress:
  - hostname: ssh-simleap.gsrpi.uk
    service: ssh://127.0.0.1:2222
  - service: http_status:404
CFG

sim_home=$(mktemp -d)
python3 -I "$here/mock_api.py" "$port" &
mock_pid=$!
cleanup() {
	kill "$mock_pid" 2>/dev/null
	rm -f "$repo/ansible/inventory.fleet-sim"
	rm -rf "$fake" "$sim_home"
	[ -n "$planted_three" ] && rm -f "$three_cfg"
}
trap cleanup EXIT
for _ in $(seq 1 20); do curl -fsS "http://127.0.0.1:$port/__state" >/dev/null 2>&1 && break; sleep 0.5; done
curl -fsS "http://127.0.0.1:$port/__state" >/dev/null || { echo "the stand-in did not start" >&2; exit 1; }

# The control node's side, in the temporary HOME: the API token, this client's fleet token,
# and an ssh config whose fleet hosts run the access-ssh script, as client-home-ssh-config.yml
# writes it. ssh reads its config from the passwd entry's home, not $HOME, so a shim on PATH
# hands it this one with -F.
export HOME="$sim_home"
install -d -m 700 "$HOME/.config/cloudflare" "$HOME/.config/fleet" "$HOME/.ssh" "$HOME/bin"
printf 'sim-token\n' > "$HOME/.config/cloudflare/api-token"
printf 'not-a-real-token\n' > "$HOME/.config/fleet/token"
chmod 600 "$HOME/.config/cloudflare/api-token" "$HOME/.config/fleet/token"
printf 'Host *\n  ProxyCommand %s/.config/fleet/access-ssh %%h\n' "$HOME" > "$HOME/.ssh/config"
real_ssh=$(command -v ssh) || { echo "no ssh client here" >&2; exit 1; }
# $HOME and $@ are the shim's to expand when it runs, not this script's.
# shellcheck disable=SC2016
printf '#!/bin/sh\nexec %s -F "$HOME/.ssh/config" "$@"\n' "$real_ssh" > "$HOME/bin/ssh"
chmod 755 "$HOME/bin/ssh"
export PATH="$HOME/bin:$PATH"

# Two enabled fleet tokens, one disabled (a revoked client), and a dev token the play must
# leave out.
control '{"service_tokens": [
  {"id": "st-sim", "name": "fleet-sim", "duration": "forever"},
  {"id": "st-laptop", "name": "fleet-laptop", "duration": "forever", "enabled": true},
  {"id": "st-lost", "name": "fleet-lost", "duration": "forever", "enabled": false},
  {"id": "st-dev", "name": "dev-sim", "duration": "forever"}]}'

cat > "$repo/ansible/inventory.fleet-sim" <<'INV'
[fleet]
three
one
simleap
# In [fleet] with no directory under hosts/ at all.
four

[control]
localhost ansible_connection=local
INV

cd "$repo/ansible" || exit 1
export ANSIBLE_CONFIG="$repo/ansible/ansible.cfg"
log="$sim_home/play.log"
play() {
	ansible-playbook -i inventory.fleet-sim playbooks/server-create-fleet-ssh-access.yml \
		-e "cf_api=$api" -e client=sim -e "control_url=$probe/control" \
		-e "fleet_url=$probe/{{ fleet_hostname }}" -e '{"ssh_probe": ["true"]}' \
		-e '{"fleet_confirm": {"user_input": "yes"}}' "$@" > "$log" 2>&1
	local rc=$?
	grep -q 'sim-token' "$log" && fail "the API token appeared in the play's output"
	tail -n 12 "$log" | sed 's/^/    | /'
	return $rc
}
# The repo's callback wraps a long message onto continuation lines marked ↪.
says() {
	python3 -I -c 'import re, sys; print(re.sub(r"\s+", " ", open(sys.argv[1]).read().replace("↪", " ")))' "$log" \
		| grep -qF "$1"
}
apps() { jq_state 'len(s["apps"])'; }

echo "== no host, a host with no tracked config, a Leap host whose ssh rule is wrong"
if play; then fail "ran with no -e host"; else
	says 'Say which box in [fleet]' && pass "refused without -e host" || fail "no -e host failed, but not by its own check"
fi
if play -e host=four; then fail "ran for a host with no tracked config"; else
	says 'hosts/four/system/cloudflared-config.yml does not exist' && pass "refused a host with no tracked config, naming system/" || fail "four failed, but not by the config check"
fi
if play -e host=simleap; then fail "ran for a wrong ssh rule"; else
	says 'hosts/simleap/leap/system/cloudflared-config.yml has no rule sending ssh-simleap.gsrpi.uk' && pass "read leap/system/ for a Leap-only host, and refused its wrong rule" || fail "simleap failed, but not by the ssh-rule check"
fi

echo "== --check: one, which has system/ and leap/system/, then three"
if play -e host=one --check; then
	says 'which hosts/one/system/cloudflared-config.yml routes' && pass "one: system/ wins over leap/system/" || fail "one: did not read system/"
else fail "one: dry run failed"; fi
if play -e host=three --check; then
	says 'which hosts/three/leap/system/cloudflared-config.yml routes' && pass "three: read leap/system/" || fail "three: did not read leap/system/"
else fail "three: dry run failed"; fi
[ "$(apps)" = 0 ] && [ "$(jq_state 'len(s["policies"])')" = 0 ] && pass "dry runs wrote nothing" || fail "a dry run wrote to Access"

echo "== the real run"
if play -e host=three; then pass "real run exits 0"; else fail "real run failed"; fi
says 'ssh-three.gsrpi.uk is gated by fleet ssh three, admitting fleet-sim, fleet-laptop' && pass "printed the final message" || fail "no final message"
got=$(jq_state '[(a["name"], a["domain"]) for a in s["apps"].values()]')
[ "$got" = "[('fleet ssh three', 'ssh-three.gsrpi.uk')]" ] && pass "one application, fleet ssh three, on ssh-three" || fail "applications: $got"
pol=$(jq_state '[(p["name"], p["decision"], sorted(i["service_token"]["token_id"] for i in p["include"])) for p in s["policies"].values()]')
[ "$pol" = "[('fleet ssh service tokens', 'non_identity', ['st-laptop', 'st-sim'])]" ] && pass "one policy, admitting the enabled fleet tokens only" || fail "policies: $pol"
[ "$(jq_state 'next(iter(s["apps"].values()))["policies"][0]["id"] == next(iter(s["policies"]))')" = True ] && pass "the application carries the policy" || fail "the application is not linked to the policy"
jq_state '[a["domain"] for a in s["apps"].values()]' | grep -q syncthing-three && fail "gated syncthing-three" || pass "left syncthing-three alone"

echo "== a re-run"
if play -e host=three; then pass "re-run exits 0"; else fail "re-run failed"; fi
[ "$(apps)" = 1 ] && [ "$(jq_state 'len(s["policies"])')" = 1 ] && pass "re-run made no second application or policy" || fail "re-run duplicated something"

echo "== the undo"
if play -e host=three -e remove=true; then pass "remove exits 0"; else fail "remove failed"; fi
[ "$(apps)" = 0 ] && pass "the application is gone" || fail "the application is still there"
[ "$(jq_state 'len(s["policies"])')" = 1 ] && pass "the policy is kept" || fail "the policy went with it"

echo "== a gate that never takes"
control '{"never_gate": true}'
if play -e host=three -e gate_retries=2 -e gate_delay=1; then fail "ran on while the hostname stayed open"; else
	says 'is open as before' && pass "the rescue undid the gate, and said so" || fail "failed, but not through the rescue"
fi
[ "$(apps)" = 0 ] && pass "no application left behind" || fail "an application was left behind"

echo
echo "requests the stand-in saw:"
state | python3 -I -c 'import json,sys; [print("  ", r) for r in json.load(sys.stdin)["requests"]]' | sort | uniq -c
echo
if [ "$fails" -gt 0 ]; then echo "$fails check(s) FAILED"; exit 1; fi
echo "all checks passed"
