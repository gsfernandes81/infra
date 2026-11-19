#!/bin/bash
# pass and fail always succeed, so `A && pass || fail` can never run both.
# shellcheck disable=SC2015
# Runs access-pair.yml against mock_api.py: server-create-deployment-tunnel.yml's two
# imports of _cf-access-app.yml, a login on pairsim.gsrpi.uk and a no-login application on
# pairsim.gsrpi.uk/kobo, the second import running after the first in one play. A dry run,
# a first run that creates both, a re-run that must write nothing, then a hand change to
# each application that only its own import may repair. Prints PASS or FAIL per check and
# exits 1 on any FAIL. CI runs it (.github/workflows/cloudflare-sim.yml).
#
# It writes nothing outside a temporary directory: no HOME, no inventory, no repo file.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
port=8790
api="http://127.0.0.1:$port/client/v4"
login=pairsim.gsrpi.uk
bypass=pairsim.gsrpi.uk/kobo
fails=0

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
state() { curl -fsS "http://127.0.0.1:$port/__state"; }
control() { curl -fsS -X POST -H 'Content-Type: application/json' -d "$1" "http://127.0.0.1:$port/__control" >/dev/null; }
jq_state() { state | python3 -I -c "import json,sys; s=json.load(sys.stdin); print($1)"; }

work=$(mktemp -d)
python3 -I "$here/mock_api.py" "$port" &
mock_pid=$!
cleanup() {
	kill "$mock_pid" 2>/dev/null
	rm -rf "$work"
}
trap cleanup EXIT
for _ in $(seq 1 20); do curl -fsS "http://127.0.0.1:$port/__state" >/dev/null 2>&1 && break; sleep 0.5; done
curl -fsS "http://127.0.0.1:$port/__state" >/dev/null || { echo "the stand-in did not start" >&2; exit 1; }

export ANSIBLE_CONFIG="$repo/ansible/ansible.cfg"
log="$work/play.log"
play() {
	ansible-playbook -i localhost, "$here/access-pair.yml" -e "cf_api=$api" "$@" > "$log" 2>&1
	local rc=$?
	grep -q 'sim-token' "$log" && fail "the API token appeared in the play's output"
	grep -qE 'owner@example\.com|second@example\.org' "$log" && fail "an allowed address appeared in the play's output"
	tail -n 12 "$log" | sed 's/^/    | /'
	return $rc
}
says() {
	python3 -I -c 'import re, sys; print(re.sub(r"\s+", " ", open(sys.argv[1]).read().replace("↪", " ")))' "$log" \
		| grep -qF -- "$1"
}
mark() { jq_state 'len(s["access_writes"])'; }
# Writes since a mark, per domain: ['pairsim.gsrpi.uk POST app', ...].
since() { jq_state "[w['domain'] + ' ' + w['method'] + ' ' + w['kind'] for w in s['access_writes'][$1:]]"; }
apps_now() { jq_state "sorted((a['domain'], a['name'], a['session_duration'], [(p['decision'], p['name'], len(p['include'])) for p in a['policies']]) for a in s['apps'].values())"; }
want="[('$login', 'pairsim', '168h', [('allow', 'allowed people', 2)]), ('$bypass', 'pairsim /kobo (no login)', '168h', [('bypass', 'no login on this path', 1)])]"

echo "== --check"
if play --check; then pass "dry run exits 0"; else fail "dry run failed"; fi
[ "$(jq_state 'len(s["apps"])')" = 0 ] && [ "$(mark)" = 0 ] && pass "dry run wrote nothing" || fail "dry run wrote Access"

echo "== the first run"
m=$(mark)
before=$(jq_state 'len(s["requests"])')
if play; then pass "first run exits 0"; else fail "first run failed"; fi
got=$(since "$m")
[ "$got" = "['$login POST app', '$login POST policy', '$bypass POST app', '$bypass POST policy']" ] \
	&& pass "created the login and its policy, then the no-login path and its policy" || fail "Access writes: $got"
[ "$(apps_now)" = "$want" ] && pass "two applications, each with its one policy" || fail "applications: $(apps_now)"
# Per import: the policies read before the write, and read back after it.
[ "$(jq_state "len([r for r in s['requests'][$before:] if r.startswith('GET') and r.endswith('/policies')])")" = 4 ] \
	&& pass "each import read its policies, and read them back" || fail "a policy read-back is missing"

echo "== a re-run"
m=$(mark)
if play; then pass "re-run exits 0"; else fail "re-run failed"; fi
got=$(since "$m")
[ "$got" = "[]" ] && pass "no PUT or POST to either application or policy" || fail "a converged re-run wrote Access: $got"
says 'if it differs, write the' && fail "a converged re-run printed an Access write" || pass "no Access write task ran, so none reads CHANGED"
# The driver is nothing but the two imports, so its recap is theirs: no changed line at all.
grep -qE '~ [0-9]+ changed' "$log" && fail "the re-run's recap counts a change" || pass "the re-run's recap counts no change"

echo "== the no-login path changed by hand, then the login"
control '{"edit_apps": {"session_duration": "24h"}}'
control "{\"edit_app_policies\": {\"include\": [{\"everyone\": {}}, {\"ip\": {\"ip\": \"192.0.2.0/24\"}}]}}"
m=$(mark)
if play; then pass "the repairing run exits 0"; else fail "the repairing run failed"; fi
got=$(since "$m")
# The stand-in applies each edit to both: both durations altered, and both policies' include
# rules replaced, the bypass policy's with its own rule plus a stray one.
[ "$got" = "['$login PUT app', '$login PUT policy', '$bypass PUT app', '$bypass PUT policy']" ] \
	&& pass "each import repaired its own application and policy" || fail "Access writes: $got"
[ "$(apps_now)" = "$want" ] && pass "both back as they were" || fail "applications: $(apps_now)"
control '{"drop_email": "second@example.org"}'
m=$(mark)
if play; then pass "a run after an address was removed exits 0"; else fail "the run after an address was removed failed"; fi
got=$(since "$m")
[ "$got" = "['$login PUT policy']" ] && pass "only the login's policy was written" || fail "Access writes: $got"
m=$(mark)
if play; then pass "the next run exits 0"; else fail "the next run failed"; fi
[ "$(since "$m")" = "[]" ] && pass "the next run wrote nothing" || fail "the next run wrote $(since "$m")"

echo
echo "requests the stand-in saw:"
state | python3 -I -c 'import json,sys; [print("  ", r) for r in json.load(sys.stdin)["requests"]]' | sort | uniq -c
echo
if [ "$fails" -gt 0 ]; then echo "$fails check(s) FAILED"; exit 1; fi
echo "all checks passed"
