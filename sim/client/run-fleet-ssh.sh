#!/bin/bash
# pass and fail always succeed, so `A && pass || fail` can never run both.
# shellcheck disable=SC2015
# Runs ansible/playbooks/client-home-ssh-config.yml --tags ssh, the blocks half, in a
# temporary HOME, and reads what ssh makes of the fleet block it writes: each box's bare
# name and <box>-cf through the tunnel, <box>-ts to its tailnet address, one HostKeyAlias
# across all three, and no -ts for a box with no address in group_vars/all.yml. Twice
# over: as a POSIX client managing the laptop's Windows file through a stand-in /mnt/c, and
# as one that cannot see the laptop and writes the paste file. Then a re-run, which must
# leave one block and change no byte, and the refusals of a tailnet address that is not
# one. Prints PASS or FAIL per check and exits 1 on any FAIL. CI runs it
# (.github/workflows/client-sim.yml).
#
# It writes nothing outside the temporary HOME. Stood in for, and so not proved by a green
# run: cloudflared and the Windows cloudflared.exe (scripts that print a version), the
# laptop (a directory), and every connection: `ssh -G` prints the configuration ssh
# resolves for a name and connects to nothing.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
fails=0

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }

sim_home=$(mktemp -d)
trap 'rm -rf "$sim_home"' EXIT
export HOME="$sim_home"
install -d -m 700 "$HOME/bin" "$HOME/.ssh"
printf '#!/bin/sh\necho "cloudflared version 2026.8.2 (sim)"\n' > "$HOME/bin/cloudflared"
chmod 755 "$HOME/bin/cloudflared"
export PATH="$HOME/bin:$PATH"
# A config with a human's own defaults, which the block must land above.
printf 'Host *\n  ServerAliveInterval 30\n' > "$HOME/.ssh/config"

win="$HOME/win"
win_cfd="$HOME/win-cloudflared.exe"
cp "$HOME/bin/cloudflared" "$win_cfd"
mkdir -p "$win"

cd "$repo/ansible" || exit 1
export ANSIBLE_CONFIG="$repo/ansible/ansible.cfg"
log="$sim_home/play.log"
play() {
	ansible-playbook playbooks/client-home-ssh-config.yml --tags ssh "$@" > "$log" 2>&1
	local rc=$?
	tail -n 8 "$log" | sed 's/^/    | /'
	return $rc
}
# The repo's callback wraps a long message onto continuation lines marked ↪.
says() {
	python3 -I -c 'import re, sys; print(re.sub(r"\s+", " ", open(sys.argv[1]).read().replace("↪", " ")))' "$log" \
		| grep -qF "$1"
}
# One keyword of what ssh resolves for a name, from one config file. Empty when unset.
resolved() { ssh -G -F "$1" "$2" 2>/dev/null | awk -v k="$3" '$1 == k { $1 = ""; sub(/^ /, ""); print; exit }'; }
markers() { grep -c '^# BEGIN infra-fleet ' "$1"; }

# Each box with a tailnet address, as the fleet's group_vars record it, read rather than
# repeated here, so a box that joins is checked without an edit to this script.
mapfile -t ts_boxes < <(python3 -I -c '
import re, sys
s = open(sys.argv[1]).read()
block = re.search(r"^tailnet_addresses:\n((?:  .*\n)+)", s, re.M).group(1)
for line in block.splitlines():
    k, v = line.strip().split(":", 1)
    print(k.strip(), v.strip())
' "$repo/ansible/group_vars/all.yml")
[ "${#ts_boxes[@]}" -gt 0 ] && pass "group_vars/all.yml records ${#ts_boxes[@]} tailnet address(es)" || fail "no tailnet_addresses read from group_vars/all.yml"

# The tunnel and tailnet entries of one config, for one render: $1 the file, $2 the
# ProxyCommand the -cf entries must carry, $3 a label.
check_render() {
	local cfg=$1 proxy=$2 label=$3 box addr
	for box in zero one two three; do
		grep -qx "Host $box $box-cf" "$cfg" && pass "$label: $box and $box-cf share one Host line" || fail "$label: no 'Host $box $box-cf' line"
		for name in "$box" "$box-cf"; do
			[ "$(resolved "$cfg" "$name" hostname)" = "ssh-$box.gsrpi.uk" ] \
				&& [ "$(resolved "$cfg" "$name" proxycommand)" = "$proxy" ] \
				&& [ "$(resolved "$cfg" "$name" hostkeyalias)" = "$box" ] \
				&& pass "$label: $name resolves to the tunnel, HostKeyAlias $box" \
				|| fail "$label: $name resolves to hostname '$(resolved "$cfg" "$name" hostname)', proxycommand '$(resolved "$cfg" "$name" proxycommand)', hostkeyalias '$(resolved "$cfg" "$name" hostkeyalias)'"
		done
	done
	local with=()
	for entry in "${ts_boxes[@]}"; do
		read -r box addr <<< "$entry"
		with+=("$box")
		[ "$(resolved "$cfg" "$box-ts" hostname)" = "$addr" ] \
			&& [ -z "$(resolved "$cfg" "$box-ts" proxycommand)" ] \
			&& [ "$(resolved "$cfg" "$box-ts" hostkeyalias)" = "$box" ] \
			&& [ "$(resolved "$cfg" "$box-ts" user)" = gavin ] \
			&& pass "$label: $box-ts resolves to $addr, no ProxyCommand, HostKeyAlias $box, User gavin" \
			|| fail "$label: $box-ts resolves to hostname '$(resolved "$cfg" "$box-ts" hostname)', proxycommand '$(resolved "$cfg" "$box-ts" proxycommand)', hostkeyalias '$(resolved "$cfg" "$box-ts" hostkeyalias)'"
		grep -qx "  HostName $addr" "$cfg" && pass "$label: $box-ts names the literal address" || fail "$label: no literal 'HostName $addr'"
	done
	for box in zero one two three; do
		[[ " ${with[*]} " == *" $box "* ]] && continue
		! grep -qE "^Host .*\b$box-ts\b" "$cfg" && [ "$(resolved "$cfg" "$box-ts" hostname)" = "$box-ts" ] \
			&& pass "$label: $box, with no address, has no -ts entry" \
			|| fail "$label: $box has a -ts entry with no address recorded"
	done
}

echo "== a refused tailnet address writes nothing"
if play -e "windows_home=$win" -e "windows_cloudflared_wsl=$win_cfd" -e '{"tailnet_addresses": {"zero": "zero.tail1234.ts.net"}}'; then
	fail "wrote a block for a MagicDNS name"
else
	says 'tailnet_addresses in group_vars/all.yml has zero: zero.tail1234.ts.net' && pass "refused a name in place of an address" || fail "a name failed, but not by the address check"
fi
if play -e "windows_home=$win" -e "windows_cloudflared_wsl=$win_cfd" -e '{"tailnet_addresses": {"thre": "100.101.45.78"}}'; then
	fail "wrote a block for a misspelt box"
else
	says 'has thre: 100.101.45.78' && pass "refused a box that is not in the fleet" || fail "a misspelt box failed, but not by the address check"
fi
grep -q 'infra-fleet' "$HOME/.ssh/config" && fail "a refused run wrote the fleet block" || pass "the refused runs wrote no fleet block"

echo "== a POSIX client with the laptop's Windows side in reach"
if play -e "windows_home=$win" -e "windows_cloudflared_wsl=$win_cfd"; then pass "run exits 0"; else fail "run failed"; fi
posix="$HOME/.ssh/config"
wcfg="$win/.ssh/config"
check_render "$posix" "$HOME/.config/fleet/access-ssh %h" posix
check_render "$wcfg" 'C:\Users\gavin\.ssh\cf-access-fleet.cmd %h' windows
[ "$(markers "$posix")" = 1 ] && [ "$(markers "$wcfg")" = 1 ] && pass "one fleet block in each file" || fail "fleet blocks: posix $(markers "$posix"), windows $(markers "$wcfg")"
awk '/^# END infra-fleet /{e=NR} /^Host \*/{h=NR} END{exit !(e && h && e < h)}' "$posix" && pass "the block sits above Host *" || fail "the block is not above Host *"
says 'without, having no address in tailnet_addresses' && pass "the play names the boxes with no -ts" || fail "the play's output does not name the boxes with no -ts"
for entry in "${ts_boxes[@]}"; do
	read -r box _ <<< "$entry"
	says "$box-ts" || fail "the play's output does not name $box-ts"
done

echo "== a re-run changes nothing"
cp "$posix" "$sim_home/posix.before"
cp "$wcfg" "$sim_home/win.before"
if play -e "windows_home=$win" -e "windows_cloudflared_wsl=$win_cfd"; then pass "re-run exits 0"; else fail "re-run failed"; fi
cmp -s "$posix" "$sim_home/posix.before" && cmp -s "$wcfg" "$sim_home/win.before" && pass "re-run left both files byte for byte" || fail "re-run changed a file"
[ "$(markers "$posix")" = 1 ] && [ "$(markers "$wcfg")" = 1 ] && pass "still one fleet block in each file" || fail "a second block after the re-run"

echo "== a client that cannot see the laptop: the paste file"
paste_file="$HOME/ssh-fleet-block-windows.txt"
if play -e "windows_home=$HOME/no-such-laptop"; then pass "run exits 0"; else fail "run failed"; fi
[ -f "$paste_file" ] && pass "wrote the paste file" || fail "no paste file"
# The block between its markers, as the owner pastes it: the rest of the file carries the
# .cmd wrapper, which is not ssh syntax.
sed -n '/^# BEGIN infra-fleet /,/^# END infra-fleet /p' "$paste_file" > "$sim_home/pasted"
[ "$(markers "$sim_home/pasted")" = 1 ] && pass "the paste file holds one marked block" || fail "the paste file holds $(markers "$sim_home/pasted") marked blocks"
check_render "$sim_home/pasted" 'C:\Users\gavin\.ssh\cf-access-fleet.cmd %h' paste

echo "== no tailnet address at all"
if play -e "windows_home=$win" -e "windows_cloudflared_wsl=$win_cfd" -e '{"tailnet_addresses": {}}'; then pass "run exits 0"; else fail "run failed"; fi
grep -qE '^Host [a-z]+-ts$' "$posix" && fail "a -ts entry with no address recorded" || pass "no -ts entries"
says 'tailnet: no box written' && pass "the play says no -ts was written" || fail "the play's output does not say no -ts was written"
[ "$(resolved "$posix" zero hostkeyalias)" = zero ] && pass "the bare names keep their HostKeyAlias" || fail "zero lost its HostKeyAlias"

echo
if [ "$fails" -gt 0 ]; then echo "$fails check(s) FAILED"; exit 1; fi
echo "all checks passed"
