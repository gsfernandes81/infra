#!/bin/bash
# pass and fail always succeed, so `A && pass || fail` can never run both.
# shellcheck disable=SC2015
# Runs ansible/playbooks/server-create-host-tunnel.yml end to end against mock_api.py, on a
# CI runner, with `three` as the runner itself: a dry run, a real run, a re-run, and the
# adverse cases (no target, a bad token, a refused write, a dead tunnel, a CNAME pointed
# elsewhere). Prints PASS or FAIL per check and exits 1 on any FAIL. CI runs it
# (.github/workflows/cloudflare-sim.yml).
#
# It writes /etc/cloudflared/three.json as root and ~/.config/cloudflare/api-token, so it
# belongs on a throwaway runner, not on a machine that has either already.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
port=8787
api="http://127.0.0.1:$port/client/v4"
creds=/etc/cloudflared/three.json
fails=0

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
state() { curl -fsS "http://127.0.0.1:$port/__state"; }
control() { curl -fsS -X POST -H 'Content-Type: application/json' -d "$1" "http://127.0.0.1:$port/__control" >/dev/null; }
jq_state() { state | python3 -I -c "import json,sys; s=json.load(sys.stdin); print($1)"; }

if [ -e "$creds" ] || [ -e "$HOME/.config/cloudflare/api-token" ]; then
	echo "refusing: $creds or ~/.config/cloudflare/api-token already exists here" >&2
	exit 1
fi

python3 -I "$here/mock_api.py" "$port" &
mock_pid=$!
trap 'kill $mock_pid 2>/dev/null; rm -f "$repo/ansible/inventory.sim" "$repo/ansible/play.log" "$repo/ansible/play-verbose.log" "$HOME/.config/cloudflare/api-token"' EXIT
for _ in $(seq 1 20); do curl -fsS "http://127.0.0.1:$port/__state" >/dev/null 2>&1 && break; sleep 0.5; done
# Every adverse case below would pass on a stand-in that never started; refuse instead.
curl -fsS "http://127.0.0.1:$port/__state" >/dev/null || { echo "the stand-in did not start" >&2; exit 1; }

install -d -m 700 "$HOME/.config/cloudflare"
printf 'sim-token\n' > "$HOME/.config/cloudflare/api-token"
chmod 600 "$HOME/.config/cloudflare/api-token"

# The inventory must sit in ansible/, because group_vars load relative to it, and those
# hold dns_zone and cf_api_token_file. It is made here and removed on exit.
cat > "$repo/ansible/inventory.sim" <<'INV'
[fleet]
three ansible_connection=local
# Never reached: the play must refuse zero, which has a tracked tunnel config, before any
# task touches it.
zero ansible_connection=local

[control]
localhost ansible_connection=local
INV

cd "$repo/ansible" || exit 1
export ANSIBLE_CONFIG="$repo/ansible/ansible.cfg"
# The repo's callback prints no ok result at all, so a missing no_log is invisible to it.
# leaks() searches a log for every secret this run knows: the token, each tunnel secret the
# stand-in received, and the credentials file as written and as slurp's base64 of it.
leaks() {
	local log=$1 secret
	grep -q 'sim-token' "$log" && fail "the API token appeared in $2"
	for secret in $(jq_state '" ".join(s["tunnel_secrets"].values())'); do
		grep -qF "$secret" "$log" && fail "a tunnel secret appeared in $2"
	done
	if sudo test -f "$creds"; then
		grep -qF "$(sudo base64 -w0 "$creds")" "$log" && fail "the credentials file, base64, appeared in $2"
	fi
	return 0
}
play() {
	ansible-playbook -i inventory.sim playbooks/server-create-host-tunnel.yml \
		-e "cf_api=$api" "$@" > play.log 2>&1
	local rc=$?
	leaks play.log "the play's output"
	tail -n 25 play.log | sed 's/^/    | /'
	return $rc
}
# The same play with the default callback at -vv, as a transcript to diagnose from would be
# made (ansible.cfg), so a result printed in full is searched too.
play_verbose() {
	ANSIBLE_STDOUT_CALLBACK=default ansible-playbook -vv -i inventory.sim \
		playbooks/server-create-host-tunnel.yml -e "cf_api=$api" "$@" > play-verbose.log 2>&1
	local rc=$?
	leaks play-verbose.log "a -vv transcript"
	rm -f play-verbose.log
	return $rc
}
says() { grep -qF "$1" play.log; }

echo "== no target, a host not in the inventory, a group name, a host that has a tunnel"
if play; then fail "ran with no -e target"; else
	says 'Name the host: -e target=' && pass "refused without -e target, with its own message" || fail "no -e target failed, but not by its own check"
fi
if play -e target=nonesuch; then fail "ran with an unknown target"; else
	says 'Name the host: -e target=' && pass "refused an unknown target" || fail "an unknown target failed, but not by its own check"
fi
if play -e target=fleet; then fail "ran with a group as the target"; else
	says 'Name the host: -e target=' && pass "refused a group as the target" || fail "a group target failed, but not by its own check"
fi
if play -e target=zero; then fail "ran against zero, which has a tunnel"; else
	says 'already has a tunnel' && pass "refused zero, which has a tracked tunnel config" || fail "zero failed, but not by the existing-tunnel check"
fi

echo "== a bad token"
printf 'not-the-token\n' > "$HOME/.config/cloudflare/api-token"
if play -e target=three; then fail "ran with a rejected token"; else
	says 'will not accept this token' && pass "stopped on a rejected token, by the token check" || fail "a rejected token failed, but not by the token check"
fi
[ -e "$creds" ] && fail "wrote credentials with a rejected token" || pass "no credentials after a rejected token"
printf 'sim-token\n' > "$HOME/.config/cloudflare/api-token"

echo "== --check"
if play -e target=three --check; then pass "dry run exits 0"; else fail "dry run failed"; fi
[ "$(jq_state 'len(s["tunnels"])')" = 0 ] && pass "dry run created no tunnel" || fail "dry run created a tunnel"
[ "$(jq_state 'len(s["records"])')" = 0 ] && pass "dry run wrote no DNS" || fail "dry run wrote DNS"
[ -e "$creds" ] && fail "dry run wrote credentials" || pass "dry run wrote no credentials"

echo "== the real run"
if play_verbose -e target=three; then pass "real run exits 0 (a -vv transcript, searched for secrets)"; else fail "real run failed"; fi
[ "$(jq_state 'len(s["tunnels"])')" = 1 ] && pass "one tunnel" || fail "tunnels: $(jq_state 'len(s["tunnels"])')"
tid=$(jq_state 'next(iter(s["tunnels"]), "")')
[ "$(jq_state 'next(iter(s["tunnels"].values()), {}).get("name")')" = three ] && pass "tunnel named three" || fail "tunnel name wrong"
rec=$(jq_state '[(r["name"], r["content"], r["proxied"]) for r in s["records"].values()]')
[ "$rec" = "[('ssh-three.gsrpi.uk', '$tid.cfargotunnel.com', True)]" ] && pass "CNAME ssh-three.gsrpi.uk -> the tunnel, proxied" || fail "records: $rec"
if sudo test -f "$creds"; then
	[ "$(sudo stat -c '%U %a' "$creds")" = "root 600" ] && pass "credentials root 600" || fail "credentials are $(sudo stat -c '%U %a' "$creds")"
	got=$(sudo cat "$creds" | python3 -I -c 'import json,sys; c=json.load(sys.stdin); print(c["TunnelID"], c["AccountTag"], c["TunnelSecret"])')
	want="$tid acct-sim $(jq_state 's["tunnel_secrets"][next(iter(s["tunnels"]))]')"
	[ "$got" = "$want" ] && pass "credentials name the tunnel, account and secret Cloudflare got" || fail "credentials do not match what Cloudflare got"
else
	fail "no credentials written"
fi
sum1=$(sudo sha256sum "$creds" 2>/dev/null)

echo "== a re-run, then the same with a -vv transcript"
if play -e target=three; then pass "re-run exits 0"; else fail "re-run failed"; fi
says "three's tunnel is $tid" && pass "printed the tunnel id" || fail "did not print the tunnel id"
if play_verbose -e target=three; then pass "a -vv re-run exits 0, searched for secrets"; else fail "a -vv re-run failed"; fi
[ "$(jq_state 'len(s["tunnels"])')" = 1 ] && pass "re-run made no second tunnel" || fail "re-run made another tunnel"
[ "$(jq_state 'len(s["records"])')" = 1 ] && pass "re-run made no second record" || fail "re-run made another record"
[ "$(sudo sha256sum "$creds" 2>/dev/null)" = "$sum1" ] && pass "re-run left the credentials as they were" || fail "re-run changed the credentials"

echo "== the CNAME pointed elsewhere, then a re-run"
control '{"repoint_records": true}'
if play -e target=three; then pass "re-run exits 0"; else fail "re-run failed"; fi
[ "$(jq_state 'next(iter(s["records"].values()))["content"]')" = "$tid.cfargotunnel.com" ] && pass "re-run pointed the CNAME back" || fail "CNAME not repaired"
[ "$(jq_state 'len(s["records"])')" = 1 ] && pass "repaired in place, not duplicated" || fail "a second record was made"

echo "== the CNAME unproxied, then a re-run"
control '{"unproxy_records": true}'
if play -e target=three; then pass "re-run exits 0"; else fail "re-run failed"; fi
[ "$(jq_state 'next(iter(s["records"].values()))["proxied"]')" = True ] && pass "re-run proxied the CNAME again" || fail "CNAME left unproxied"

echo "== the tunnel deleted at Cloudflare, then a re-run"
control '{"delete_tunnels": true}'
if play -e target=three; then fail "ran on with credentials naming a dead tunnel"; else
	says 'which this account does not have' && pass "stopped on a dead tunnel, by its check" || fail "a dead tunnel failed, but not by its check"
fi
[ "$(jq_state 'len(s["tunnels"])')" = 1 ] && pass "made no replacement tunnel by itself" || fail "made a replacement tunnel"

echo "== a refused write, from a clean start"
control '{"reset": true}'
sudo rm -f "$creds"
control '{"refuse_writes": true}'
if play -e target=three; then fail "ran on through a refused write"; else pass "stopped on a refused write"; fi
grep -q 'may not edit tunnels' play.log && pass "printed Cloudflare's reason" || fail "did not print Cloudflare's reason"
[ -e "$creds" ] && fail "wrote credentials for a tunnel that was refused" || pass "no credentials after a refused write"

echo "== a partial failure: the tunnel made, the DNS refused, then a re-run"
control '{"reset": true}'
sudo rm -f "$creds"
control '{"refuse_dns": true}'
if play -e target=three; then fail "ran on through a refused DNS write"; else
	says 'does not point at this tunnel' && pass "stopped on a refused DNS write, by its check" || fail "a refused DNS write failed, but not by its check"
fi
[ "$(jq_state 'len(s["tunnels"])')" = 1 ] && sudo test -f "$creds" && pass "the tunnel and its credentials exist" || fail "the partial run did not leave a tunnel and credentials"
control '{"refuse_dns": false}'
if play -e target=three; then pass "the re-run finished the job"; else fail "the re-run after a partial failure failed"; fi
[ "$(jq_state 'len(s["tunnels"])')" = 1 ] && [ "$(jq_state 'len(s["records"])')" = 1 ] && pass "one tunnel, one record after finishing" || fail "the re-run duplicated something"

echo "== the credentials lost after the tunnel was made, then a re-run"
sudo rm -f "$creds"
if play -e target=three; then fail "ran on with the name taken by its own lost tunnel"; else
	says 'already have a tunnel with this name' && pass "stopped on the name in use, and printed Cloudflare's reason" || fail "the name in use failed, but not by its check"
fi
[ "$(jq_state 'len(s["tunnels"])')" = 1 ] && pass "made no second tunnel" || fail "made a second tunnel"

echo "== a stale A record at the hostname, from a clean start"
control '{"reset": true}'
sudo rm -f "$creds"
control '{"plant_a_record": "ssh-three.gsrpi.uk"}'
if play -e target=three; then fail "ran on with an A record in the way"; else
	says 'record with that host already exists' && pass "stopped on an A record in the way, and printed Cloudflare's reason" || fail "an A record in the way failed, but not by its check"
fi

echo
echo "requests the stand-in saw:"
state | python3 -I -c 'import json,sys; [print("  ", r) for r in json.load(sys.stdin)["requests"]]' | sort | uniq -c
echo
if [ "$fails" -gt 0 ]; then echo "$fails check(s) FAILED"; exit 1; fi
echo "all checks passed"
