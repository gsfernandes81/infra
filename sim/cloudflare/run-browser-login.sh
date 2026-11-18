#!/bin/bash
# pass and fail always succeed, so `A && pass || fail` can never run both.
# shellcheck disable=SC2015
# Runs ansible/playbooks/server-create-browser-login.yml against mock_api.py for
# syncthing-three on `three`, whose tunnel config is under leap/system/: the refusals, a dry
# run, a real run, a re-run, a refused Access write, and the two ways the proof can fail
# after the record exists (the hostname open, and no answer at all). Checks that the login
# exists before the CNAME is written, from the stand-in's own record of each DNS write.
# Prints PASS or FAIL per check and exits 1 on any FAIL. CI runs it
# (.github/workflows/cloudflare-sim.yml).
#
# It writes nothing outside a temporary HOME except, in the repo, an inventory beside
# ansible.cfg, hosts/simleap/, and three's stand-in config when there is none, all removed
# on exit. The edge is stood in for: the probe URLs point at the stand-in, which answers a
# 302 to a cloudflareaccess.com login for a hostname an allow application covers.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
port=8789
api="http://127.0.0.1:$port/client/v4"
login="http://127.0.0.1:$port/__login"
three_cfg="$repo/hosts/three/leap/system/cloudflared-config.yml"
fake="$repo/hosts/simleap"
web=syncthing-three.gsrpi.uk
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
    originRequest:
      httpHostHeader: localhost
  - service: http_status:404
CFG
fi
tunnel=$(sed -n 's/^tunnel: *//p' "$three_cfg")
# A Leap-only host whose tracked routing names no tunnel.
mkdir -p "$fake/leap/system"
cat > "$fake/leap/system/cloudflared-config.yml" <<'CFG'
ingress:
  - hostname: web-simleap.gsrpi.uk
    service: http://127.0.0.1:8080
  - service: http_status:404
CFG

sim_home=$(mktemp -d)
python3 -I "$here/mock_api.py" "$port" &
mock_pid=$!
cleanup() {
	kill "$mock_pid" 2>/dev/null
	rm -f "$repo/ansible/inventory.login-sim"
	rm -rf "$fake" "$sim_home"
	[ -n "$planted_three" ] && rm -f "$three_cfg"
}
trap cleanup EXIT
for _ in $(seq 1 20); do curl -fsS "http://127.0.0.1:$port/__state" >/dev/null 2>&1 && break; sleep 0.5; done
curl -fsS "http://127.0.0.1:$port/__state" >/dev/null || { echo "the stand-in did not start" >&2; exit 1; }

# The control node's side, in the temporary HOME: the API token and who may log in.
export HOME="$sim_home"
install -d -m 700 "$HOME/.config/cloudflare"
printf 'sim-token\n' > "$HOME/.config/cloudflare/api-token"
chmod 600 "$HOME/.config/cloudflare/api-token"
emails="$HOME/.config/cloudflare/access-emails"

# What the fleet has by slice 4: three's tunnel, and ssh-three's record pointing at it.
fleet_state() {
	control '{"reset": true}'
	control "{\"plant_tunnel\": {\"id\": \"$tunnel\", \"name\": \"three\"},
	          \"plant_cname\": {\"name\": \"ssh-three.gsrpi.uk\", \"content\": \"$tunnel.cfargotunnel.com\"}}"
}
fleet_state

cat > "$repo/ansible/inventory.login-sim" <<'INV'
[fleet]
three
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
	ansible-playbook -i inventory.login-sim playbooks/server-create-browser-login.yml \
		-e "cf_api=$api" -e "calibration_url=$login/control" \
		-e "web_url=$login/{{ web_hostname }}" -e probe_retries=3 -e probe_delay=1 "$@" > "$log" 2>&1
	local rc=$?
	grep -q 'sim-token' "$log" && fail "the API token appeared in the play's output"
	grep -qE 'owner@example\.com|second@example\.org' "$log" && fail "an allowed address appeared in the play's output"
	tail -n 12 "$log" | sed 's/^/    | /'
	return $rc
}
# The repo's callback wraps a long message onto continuation lines marked ↪.
says() {
	python3 -I -c 'import re, sys; print(re.sub(r"\s+", " ", open(sys.argv[1]).read().replace("↪", " ")))' "$log" \
		| grep -qF -- "$1"
}
apps() { jq_state 'len(s["apps"])'; }
web_records() { jq_state "len([r for r in s['records'].values() if r['name'] == '$web'])"; }
nothing_made() { [ "$(apps)" = 0 ] && [ "$(web_records)" = 0 ]; }
requests() { jq_state 'len(s["requests"])'; }

echo "== no host, a host with no tracked config, a Leap host with no tunnel id"
if play -e subdomain=syncthing-three; then fail "ran with no -e host"; else
	says 'Say which box in [fleet]' && pass "refused without -e host" || fail "no -e host failed, but not by its own check"
fi
if play -e host=four -e subdomain=web-four; then fail "ran for a host with no tracked config"; else
	says 'hosts/four/system/cloudflared-config.yml does not exist' && pass "refused a host with no tracked config" || fail "four failed, but not by the config check"
fi
if play -e host=simleap -e subdomain=web-simleap; then fail "ran for a config with no tunnel id"; else
	says 'hosts/simleap/leap/system/cloudflared-config.yml has no' && pass "read leap/system/, and refused a config with no tunnel id" || fail "simleap failed, but not by the tunnel-id check"
fi

echo "== subdomains that are not a browser rule on three"
if play -e host=three; then fail "ran with no -e subdomain"; else
	says "Its browser hostnames: $web" && pass "refused without -e subdomain, listing $web" || fail "no -e subdomain failed, but not by its own check"
fi
if play -e host=three -e subdomain=ssh-three; then fail "ran for ssh-three"; else
	says "got 'ssh-three'" && pass "refused ssh-three, which is the fleet ssh play's" || fail "ssh-three failed, but not by the rule check"
fi
if play -e host=three -e subdomain=nope; then fail "ran for a hostname not in the ingress"; else
	says "got 'nope'" && pass "refused a hostname not in the ingress" || fail "nope failed, but not by the rule check"
fi
nothing_made && pass "no refusal so far made anything" || fail "a refusal made something"

echo "== who may log in"
if play -e host=three -e subdomain=syncthing-three; then fail "ran with no address list"; else
	says 'NO ACCESS EMAIL LIST' && pass "refused with no address list, printing how to make one" || fail "no list failed, but not by its own check"
fi
printf 'owner@example.com\nnot an address\n' > "$emails"
if play -e host=three -e subdomain=syncthing-three; then fail "ran with a malformed address"; else
	says 'must look like an address' && pass "refused a malformed address" || fail "a malformed address failed, but not by its own check"
fi
printf '# who may log in\nowner@example.com\n\nsecond@example.org\n' > "$emails"
nothing_made && pass "still nothing made" || fail "an address refusal made something"

echo "== the tunnel: deleted, and not the one ssh-three uses"
control '{"reset": true}'
if play -e host=three -e subdomain=syncthing-three; then fail "ran with no live tunnel"; else
	says 'which this account does not have' && pass "refused a tunnel the account does not have" || fail "no tunnel failed, but not by the live check"
fi
control "{\"plant_tunnel\": {\"id\": \"$tunnel\", \"name\": \"three\"},
          \"plant_cname\": {\"name\": \"ssh-three.gsrpi.uk\", \"content\": \"11111111-1111-1111-1111-111111111111.cfargotunnel.com\"}}"
if play -e host=three -e subdomain=syncthing-three; then fail "ran while ssh-three points elsewhere"; else
	says 'does not CNAME to' && pass "refused a tracked tunnel that ssh-three does not use" || fail "the mismatch failed, but not by its own check"
fi
nothing_made && pass "still nothing made" || fail "a tunnel refusal made something"

echo "== an application on the hostname this play did not make, and a probe that cannot see a login"
fleet_state
control "{\"plant_app\": {\"name\": \"syncthing gui (by hand)\", \"domain\": \"$web\"}}"
if play -e host=three -e subdomain=syncthing-three; then fail "ran over a foreign application"; else
	says 'already covered by Access applications this play did not make' && pass "refused a foreign application" || fail "the foreign app failed, but not by its own check"
fi
[ "$(web_records)" = 0 ] && pass "no record made" || fail "a record was made over a foreign application"
fleet_state
if play -e host=three -e subdomain=syncthing-three -e "calibration_url=$login/no-login-here"; then fail "ran with an uncalibrated probe"; else
	says 'not an Access login, so this probe could not recognise one' && pass "refused when the known login does not read as one" || fail "calibration failed, but not by its own check"
fi
nothing_made && pass "nothing made before the probe was calibrated" || fail "something was made before calibration"

echo "== --check"
if play -e host=three -e subdomain=syncthing-three --check; then
	says '--check: would create the Access application syncthing-three' && pass "dry run says what it would do" || fail "dry run printed no plan"
else fail "dry run failed"; fi
nothing_made && [ "$(jq_state 'len(s["dns_writes"])')" = 0 ] && pass "dry run wrote nothing" || fail "dry run wrote something"

echo "== the real run"
before=$(requests)
if play -e host=three -e subdomain=syncthing-three; then pass "real run exits 0"; else fail "real run failed"; fi
says "https://$web/ is behind the Access login syncthing-three" && pass "printed the GUI's address" || fail "no final message"
got=$(jq_state '[(a["name"], a["domain"], a["session_duration"]) for a in s["apps"].values()]')
[ "$got" = "[('syncthing-three', '$web', '24h')]" ] && pass "one application, syncthing-three, on $web, 24h" || fail "applications: $got"
pol=$(jq_state '[(p["name"], p["decision"], sorted(i["email"]["email"] for i in p["include"])) for a in s["apps"].values() for p in a["policies"]]')
[ "$pol" = "[('allowed people', 'allow', ['owner@example.com', 'second@example.org'])]" ] && pass "one allow policy, admitting the two addresses" || fail "policies: $pol"
rec=$(jq_state "[(r['content'], r['proxied']) for r in s['records'].values() if r['name'] == '$web']")
[ "$rec" = "[('$tunnel.cfargotunnel.com', True)]" ] && pass "one proxied CNAME to three's tunnel" || fail "records: $rec"
[ "$(jq_state "[w['login'] for w in s['dns_writes'] if w['name'] == '$web']")" = "[True]" ] && pass "the login covered $web when its CNAME was written" || fail "the CNAME went out before the login"
order=$(jq_state "[i for i, r in enumerate(s['requests'][$before:]) if r.startswith('POST') and ('/policies' in r or '/dns_records' in r)]")
kinds=$(jq_state "[r.split('/')[-1] for r in s['requests'][$before:] if r.startswith('POST') and ('/policies' in r or '/dns_records' in r)]")
[ "$kinds" = "['policies', 'dns_records']" ] && pass "requests: the policy, then the record ($order)" || fail "request order: $kinds"

echo "== a re-run"
before=$(requests)
if play -e host=three -e subdomain=syncthing-three; then pass "re-run exits 0"; else fail "re-run failed"; fi
[ "$(apps)" = 1 ] && [ "$(jq_state 'sum(len(a["policies"]) for a in s["apps"].values())')" = 1 ] && pass "no second application or policy" || fail "re-run duplicated Access"
[ "$(jq_state "len([r for r in s['requests'][$before:] if '/dns_records' in r and not r.startswith('GET')])")" = 0 ] && pass "the record was left as it was" || fail "re-run rewrote the record"
[ "$(web_records)" = 1 ] && pass "still one record" || fail "re-run changed the record count"
says 'already CNAMEs to this tunnel, proxied' && pass "said the CNAME is left alone" || fail "did not say the CNAME was left"
# Pointed elsewhere by hand: a re-run repairs it, with the login still in front.
control '{"repoint_records": true}'
fleet_state_ssh_fix() { control "{\"plant_cname\": {\"name\": \"ssh-three.gsrpi.uk\", \"content\": \"$tunnel.cfargotunnel.com\"}}"; }
# repoint_records moves ssh-three too; put a correct one back beside it.
fleet_state_ssh_fix
if play -e host=three -e subdomain=syncthing-three; then pass "re-run after the record moved exits 0"; else fail "re-run after the record moved failed"; fi
rec=$(jq_state "[(r['content'], r['proxied']) for r in s['records'].values() if r['name'] == '$web']")
[ "$rec" = "[('$tunnel.cfargotunnel.com', True)]" ] && pass "the moved record was pointed back" || fail "records: $rec"

echo "== a refused Access write"
fleet_state
control '{"refuse_access": true}'
if play -e host=three -e subdomain=syncthing-three; then fail "ran on with Access refused"; else
	says 'A 403 means the API token lacks' && pass "stopped on the refusal, naming the permission" || fail "Access refusal failed, but not by its own check"
fi
says 'may not edit Access' && pass "printed Cloudflare's reason" || fail "Cloudflare's reason was not printed"
[ "$(web_records)" = 0 ] && pass "no record without a login" || fail "a record was written with Access refused"

echo "== the hostname answers from behind Access after the record"
fleet_state
control '{"never_gate": true}'
if play -e host=three -e subdomain=syncthing-three; then fail "ran on while the hostname was open"; else
	says 'The CNAME was deleted' && pass "the rescue deleted the record, and said so" || fail "failed, but not through the rescue"
fi
[ "$(web_records)" = 0 ] && pass "no record left behind" || fail "the record was left behind while open"
[ "$(apps)" = 1 ] && pass "the login application is kept" || fail "the login application went too"
says 'after 3s' && fail "probed an open hostname for the whole wait" || pass "stopped at the first answer, without waiting out the retries"
fleet_state
control '{"never_gate": true, "delete_answer": "gone"}'
if play -e host=three -e subdomain=syncthing-three; then fail "ran on while the hostname was open"; else
	says 'The CNAME was deleted' && pass "a 404 on the delete reads as gone" || fail "a 404 on the delete was not read as gone"
fi
fleet_state
control '{"never_gate": true, "delete_answer": "refuse"}'
if play -e host=three -e subdomain=syncthing-three; then fail "ran on while the hostname was open"; else
	says 'THE CNAME COULD NOT BE DELETED (HTTP 403)' && pass "a refused delete says the hostname may be open" || fail "a refused delete was not reported"
	says 'may not delete DNS' && pass "printed Cloudflare's reason for the refused delete" || fail "the refused delete's reason was not printed"
fi
[ "$(web_records)" = 1 ] && pass "the refused delete left the record, as reported" || fail "the stand-in lost the record"
control '{"delete_answer": null}'

echo "== no answer at all after the record"
fleet_state
if play -e host=three -e subdomain=syncthing-three -e 'web_url=http://127.0.0.1:9/'; then fail "ran on with no answer"; else
	says 'does not answer from here yet' && pass "no answer: said to re-run" || fail "no answer failed, but not through the rescue"
	# The calibration for the open case's "stopped at the first answer": no answer is
	# retried to the end, and says so.
	says 'after 3s' && pass "no answer: retried for the whole wait" || fail "no answer was not retried"
fi
[ "$(web_records)" = 1 ] && pass "the record is kept when nothing answered" || fail "the record was deleted on no answer"
if play -e host=three -e subdomain=syncthing-three; then pass "the re-run then finishes"; else fail "the re-run after no answer failed"; fi

echo
echo "requests the stand-in saw:"
state | python3 -I -c 'import json,sys; [print("  ", r) for r in json.load(sys.stdin)["requests"]]' | sort | uniq -c
echo
if [ "$fails" -gt 0 ]; then echo "$fails check(s) FAILED"; exit 1; fi
echo "all checks passed"
