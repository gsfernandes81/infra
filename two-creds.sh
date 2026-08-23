#!/bin/sh
# two-creds.sh — 2f + the token move on `two`, in one edit to one file.
# ONE-SHOT. DELETE AFTER RUNNING.
#
# WHY BOTH AT ONCE. Two's token is INLINE in /etc/init.d/cloudflared (mode 755,
# world-readable). That is why the file has never been tracked, and tracking it is what
# 2f requires. So the logging fix and the token move are the same edit to the same file
# — not bundling, one change.
#
# It goes straight to a credentials file rather than via /etc/conf.d, which is what zero
# and one did in August. That is deliberate: conf.d would be a new place for a secret
# to live and a later step to undo. This way it never exists here.
#
# The token VALUE is unchanged. Rotation comes when 2g retires this tunnel — and
# retiring it is stronger than rotating, because it kills the disclosed credential
# outright rather than superseding it.
#
# INTERRUPT SAFETY. A stop/sleep/start pasted as three commands left zero's tunnel down
# for 45 minutes on 2026-08-23 when the sleep was interrupted. The trap below starts the
# service again on INT or TERM, so ^C cannot leave this box dark.
set -u

REPO=/home/gavin/infra
INIT=/etc/init.d/cloudflared
CFGDIR=/etc/cloudflared
CFG=$CFGDIR/config.yml
CRED=$CFGDIR/two.json
BAK=/root/cf-two-rollback
ST=/root/two-creds.status
M=http://127.0.0.1:20241
DEADLINE=60

say() { printf '%s  %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "$ST"; }
jnum() { sed -n "s/.*\"$1\":\([0-9]*\).*/\1/p"; }
jstr() { sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p"; }
nrules() { grep -o '"hostname":"' | wc -l; }
port_held() { netstat -tln 2>/dev/null | grep -q '127\.0\.0\.1:20241 '; }

trap 'say "INTERRUPTED — bringing the service back up"; rc-service cloudflared start >/dev/null 2>&1; exit 130' INT TERM

cycle() {
    rc-service cloudflared stop >/dev/null 2>&1
    i=0
    while [ "$i" -lt 45 ]; do port_held || break; i=$((i + 2)); sleep 2; done
    port_held && { say "20241 still held after 45s"; return 1; }
    rc-service cloudflared start >/dev/null 2>&1
}

[ "$(id -u)" -eq 0 ] || { echo "run me as root"; exit 1; }
: > "$ST"; chmod 600 "$ST"
mkdir -p "$BAK"; chmod 700 "$BAK"
say "two: token out of the 755 init script, and logging that works"

# ── calibrate against the working tunnel ───────────────────────────────────────
r=$(curl -sf --max-time 5 "$M/ready") || { say "FAIL: /ready unreachable now. Nothing changed."; exit 1; }
cid0=$(printf '%s' "$r" | jstr connectorId)
n0=$(printf '%s' "$r" | jnum readyConnections)
[ "${n0:-0}" -ge 1 ] || { say "FAIL: tunnel unhealthy now (readyConnections=${n0:-?})"; exit 1; }
nb=$(curl -sf --max-time 5 "$M/config" | nrules)
say "baseline: connectorId $cid0, $n0 connections, $nb ingress rules"
[ "${nb:-0}" -ge 1 ] || { say "FAIL: no ingress rules reported"; exit 1; }

for f in "$REPO/hosts/two/system/cloudflared" "$REPO/hosts/two/system/cloudflared-config.yml"; do
    [ -f "$f" ] || { say "FAIL: missing $f — git pull on this host?"; exit 1; }
done

# ── take the token OUT of the init script, before anything overwrites it ───────
tokv=$(grep -o 'eyJ[A-Za-z0-9_.=-]*' "$INIT" | head -1)
[ -n "$tokv" ] || { say "FAIL: no token found in $INIT"; exit 1; }
pad=$(( ${#tokv} % 4 )); t2=$tokv
[ "$pad" -eq 2 ] && t2="$t2=="
[ "$pad" -eq 3 ] && t2="$t2="
dec=$(printf '%s' "$t2" | base64 -d 2>/dev/null) || { say "FAIL: token is not valid base64"; exit 1; }
acct=$(printf '%s' "$dec" | jstr a)
tid=$(printf '%s' "$dec" | jstr t)
sec=$(printf '%s' "$dec" | jstr s)
unset dec t2 tokv
[ -n "$acct" ] && [ -n "$tid" ] && [ -n "$sec" ] || { say "FAIL: decoded token has no a/t/s"; exit 1; }

want=$(sed -n 's/^tunnel: *//p' "$REPO/hosts/two/system/cloudflared-config.yml")
[ "$want" = "$tid" ] || { say "FAIL: config.yml is tunnel $want, the token is $tid"; exit 1; }
say "token decodes to tunnel $tid — matches the reviewed config.yml"

# Backup at 0600 OUTSIDE /etc/init.d. On `one` an August backup was left in that
# directory at 755 with the token still in it, and sat there for a month.
cp -a "$INIT" "$BAK/init.d-cloudflared"; chmod 600 "$BAK/init.d-cloudflared"
printf '%s\n' "$cid0" > "$BAK/connectorId-before"
say "backed up the original init script to $BAK (0700, file 0600)"

rollback() {
    say "ROLLING BACK: $1"
    cp -a "$BAK/init.d-cloudflared" "$INIT"; chmod 0755 "$INIT"
    rm -f "$CRED"
    cycle
    i=0
    while [ "$i" -lt "$DEADLINE" ]; do
        x=$(curl -sf --max-time 5 "$M/ready" 2>/dev/null) && {
            m=$(printf '%s' "$x" | jnum readyConnections)
            [ "${m:-0}" -ge 1 ] && { say "rollback OK — $m connections"; exit 1; }
        }
        i=$((i + 5)); sleep 5
    done
    say "*** ROLLBACK FAILED — tunnel DOWN. Backup in $BAK ***"
    exit 2
}

mkdir -p "$CFGDIR"; chmod 0755 "$CFGDIR"
( umask 077; printf '{"AccountTag":"%s","TunnelID":"%s","TunnelSecret":"%s"}\n' \
    "$acct" "$tid" "$sec" > "$CRED" )
chmod 600 "$CRED"; chown root:root "$CRED"
unset sec acct
say "wrote $CRED (0600 root:root)"

"$REPO/bin/install-system-file" cloudflared-config.yml --commit --new \
    --allow-content-change >>"$ST" 2>&1 || rollback "install-system-file refused config.yml"
"$REPO/bin/install-system-file" cloudflared --commit --allow-content-change \
    >>"$ST" 2>&1 || rollback "install-system-file refused the init script"
say "installed $CFG and $INIT"

say "cycling (stop, wait for 20241, start)"
cycle || rollback "could not cycle cleanly"

i=0; ok=
while [ "$i" -lt "$DEADLINE" ]; do
    x=$(curl -sf --max-time 5 "$M/ready" 2>/dev/null) && {
        m=$(printf '%s' "$x" | jnum readyConnections)
        c=$(printf '%s' "$x" | jstr connectorId)
        [ "${m:-0}" -ge 1 ] && [ -n "$c" ] && [ "$c" != "$cid0" ] && { ok=1; say "connector $c (was $cid0), $m connections"; break; }
    }
    i=$((i + 5)); sleep 5
done
[ -n "$ok" ] || rollback "no healthy connector with a new connectorId in ${DEADLINE}s"

na=$(curl -sf --max-time 5 "$M/config" | nrules)
say "ingress rules: $na (was $nb)"
[ "$na" -eq "$nb" ] || rollback "rule count changed"

if grep -q 'eyJ' "$INIT"; then rollback "the token is STILL in $INIT"; fi
if xargs -0 -n1 echo < /proc/"$(cat /var/run/cloudflared.pid)"/cmdline | grep -q eyJ; then
    rollback "the token is STILL in argv"
fi
say "confirmed: no token in the init script, none in argv"

ls -l /var/log/cloudflared.log | tee -a "$ST"
say "DONE. CLEANUP: rm -rf $BAK, and /var/log/cloudflared.err is stale (16 July)."
