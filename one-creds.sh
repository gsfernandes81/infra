#!/bin/sh
# one-creds.sh — move one's tunnel token out of argv into a credentials file.
# ONE-SHOT. DELETE AFTER RUNNING. Same change zero had earlier today.
#
# The token VALUE does not change. A tunnel token IS the credentials — base64 of
# {"a":AccountTag,"t":TunnelID,"s":Secret} — so this needs no Cloudflare access and no
# new secret. Rotating it happens later, by retiring this tunnel under 2g.
#
# Everything is backed up before anything is written, and any failed check restores both
# files and cycles back. Exit 0 = serving; 1 = rolled back; 2 = rollback failed.
set -u

REPO=/home/gavin/infra
CONF=/etc/conf.d/cloudflared
INIT=/etc/init.d/cloudflared
CFGDIR=/etc/cloudflared
CFG=$CFGDIR/config.yml
CRED=$CFGDIR/one.json
BAK=/root/cf-one-rollback
ST=/root/one-creds.status
M=http://127.0.0.1:20241
DEADLINE=60

say() { printf '%s  %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "$ST"; }
jnum() { sed -n "s/.*\"$1\":\([0-9]*\).*/\1/p"; }
jstr() { sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p"; }
nrules() { grep -o '"hostname":"' | wc -l; }
port_held() { netstat -tln 2>/dev/null | grep -q '127\.0\.0\.1:20241 '; }

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
say "moving one's token out of argv — value unchanged"

# ── calibrate against the working tunnel ───────────────────────────────────────
r=$(curl -sf --max-time 5 "$M/ready") || { say "FAIL: /ready unreachable now. Nothing changed."; exit 1; }
cid0=$(printf '%s' "$r" | jstr connectorId)
n0=$(printf '%s' "$r" | jnum readyConnections)
[ "${n0:-0}" -ge 1 ] || { say "FAIL: tunnel unhealthy now (readyConnections=${n0:-?})"; exit 1; }
nb=$(curl -sf --max-time 5 "$M/config" | nrules)
say "baseline: connectorId $cid0, $n0 connections, $nb ingress rules"
[ "$nb" -ge 5 ] || { say "FAIL: expected at least 5 rules, got $nb"; exit 1; }

for f in "$REPO/hosts/one/system/cloudflared" "$REPO/hosts/one/system/cloudflared-config.yml"; do
    [ -f "$f" ] || { say "FAIL: missing $f — did you git pull?"; exit 1; }
done

# ── derive the credentials from the token already in conf.d ────────────────────
CF_TUNNEL_TOKEN=
. "$CONF"
[ -n "${CF_TUNNEL_TOKEN:-}" ] || { say "FAIL: no CF_TUNNEL_TOKEN in $CONF"; exit 1; }
pad=$(( ${#CF_TUNNEL_TOKEN} % 4 )); tok=$CF_TUNNEL_TOKEN
[ "$pad" -eq 2 ] && tok="$tok=="
[ "$pad" -eq 3 ] && tok="$tok="
dec=$(printf '%s' "$tok" | base64 -d 2>/dev/null) || { say "FAIL: token is not valid base64"; exit 1; }
acct=$(printf '%s' "$dec" | jstr a)
tid=$(printf '%s' "$dec" | jstr t)
sec=$(printf '%s' "$dec" | jstr s)
unset dec tok
[ -n "$acct" ] && [ -n "$tid" ] && [ -n "$sec" ] || { say "FAIL: decoded token has no a/t/s"; exit 1; }

want=$(sed -n 's/^tunnel: *//p' "$REPO/hosts/one/system/cloudflared-config.yml")
[ "$want" = "$tid" ] || { say "FAIL: config.yml is tunnel $want, the token is $tid"; exit 1; }
say "token decodes to tunnel $tid — matches the reviewed config.yml"

# ── back up before writing ─────────────────────────────────────────────────────
cp -a "$INIT" "$BAK/init.d-cloudflared"; chmod 600 "$BAK/init.d-cloudflared"
cp -a "$CONF" "$BAK/conf.d-cloudflared"; chmod 600 "$BAK/conf.d-cloudflared"
printf '%s\n' "$cid0" > "$BAK/connectorId-before"
say "backed up init.d and conf.d into $BAK"

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
    say "*** ROLLBACK FAILED — tunnel DOWN. Backups in $BAK ***"
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
[ "$na" -eq "$nb" ] || rollback "rule count changed — remote config is not being served"

if xargs -0 -n1 echo < /proc/"$(cat /var/run/cloudflared.pid)"/cmdline | grep -q eyJ; then
    rollback "the token is STILL in argv"
fi
say "confirmed: no token in argv"

say "DONE. CLEANUP: $CONF now holds an unused token — remove it, and $BAK too."
