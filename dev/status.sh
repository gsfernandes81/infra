#!/usr/bin/env bash
# The readouts for infra-dev, on the HOST side: what state the container is in, what a
# rebuild landed, and the start-up lines. Called by dev/Makefile —
#
#     make status | make verify | make boot-log | make fleet
#
# — and not meant to be run directly, though nothing stops you: it takes SUDO and
# CONTAINER from the environment and defaults both.
#
# It only ever READS. Everything that changes the container is a Makefile target;
# keeping the two apart is what makes it safe to run any of this at any time,
# including against a container that is not there.
set -u

CONTAINER="${CONTAINER:-infra-dev}"
DOCKER=(${SUDO:-} docker)

d() { "${DOCKER[@]}" "$@"; }

# ── status ──────────────────────────────────────────────────────────────────
status() {
    # One read of every process's cmdline, used by the lines below. Straight out of
    # /proc rather than `pgrep`, because procps is not in the image's package list: if
    # pgrep is absent, `pgrep … || echo "no daemon"` reports a healthy daemon as
    # missing, and a status line that lies is worse than one that is not there.
    local procs
    procs="$(d exec "$CONTAINER" sh -c \
        'for p in /proc/[0-9]*/cmdline; do tr "\0" " " < "$p" 2>/dev/null; echo; done' 2>/dev/null || true)"

    # Container ID, not StartedAt: StartedAt necessarily changes across a legitimate
    # stop/start, so it cannot tell a cycle from a recreate. The ID can. oom is here
    # because mem_limit is lower than or3-dev's and an OOM kill is the expected way
    # for that to be wrong.
    printf 'container : %s\n' "$(d inspect -f '{{.Name}} {{.State.Status}} id={{slice .Id 0 12}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}}' "$CONTAINER" 2>/dev/null || echo 'absent')"
    printf 'published : %s\n' "$(d port "$CONTAINER" 2222/tcp 2>/dev/null || echo 'none')"

    # sshd is the container's foreground process, so this line and the container's own
    # status say the same thing from two directions. If they ever disagree, believe
    # this one: a container can be `running` with its payload dead only if something
    # has gone wrong in a way worth seeing spelled out.
    printf 'sshd      : %s\n' "$(grep -q 'sshd' <<<"$procs" \
        && echo 'running in the foreground (the way in)' \
        || echo 'NOT running — nothing to ssh into; see: make boot-log')"

    # The sessions are the work: this is where a claude lives. Read as the SOCKET
    # DIRECTORY rather than by running `abduco` — abduco's own listing carries a header
    # and wants a terminal, and a status check must be able to tell "no sessions" from
    # "the listing did not work". One socket, one session; abduco removes it when the
    # session ends.
    local sessions
    sessions="$(d exec "$CONTAINER" sh -c 'ls -1 "$HOME/.abduco" 2>/dev/null' 2>/dev/null)"
    if [ -n "$sessions" ]; then
        printf 'sessions  : abduco — %s\n' "$(tr '\n' ' ' <<<"$sessions" | sed 's/ *$//')"
    else
        printf 'sessions  : %s\n' 'no abduco sessions (make claude, or ssh in and start one)'
    fi

    printf 'claude    : %s\n' "$(grep 'claude' <<<"$procs" \
        | grep -vE 'offload-idle-claude|/proc/' | grep -q . \
        && echo 'a claude is running in this container' || echo 'no claude running')"

    # `claude auth status`, not "is there a credentials file" — a file holding empty
    # tokens exists and reports logged out, so the file's presence proves nothing.
    printf 'auth      : %s\n' "$(d exec "$CONTAINER" claude auth status 2>/dev/null | grep -q '"loggedIn": *true' \
        && echo 'claude logged in' || echo 'claude NOT logged in — run: make login')"
    printf 'gh        : %s\n' "$(d exec "$CONTAINER" gh auth status 2>/dev/null | grep -m1 'Logged in' | sed 's/^[[:space:]]*//' \
        | grep . || echo 'NOT logged in — run: make login (git push works without it)')"

    # The two files that decide whether this container can reach the fleet at all.
    # Named separately because they fail differently: no ssh_config.fleet is "unknown
    # host zero", no known_hosts.fleet is a host key failure that reads like a refused
    # connection. Neither is written by anything in the repo today.
    # Absent is the DEFAULT here, not a fault. Fleet access is opt-in
    # (INFRA_DEV_FLEET=1) because it makes this a control node running on a box it
    # controls, which is a deferred question rather than a settled one. So the line says
    # "not configured", and only says something is wrong when the set is half-present —
    # a key with no host keys fails on verification in a way that reads as a refused
    # connection, which is the state worth naming.
    printf 'fleet     : %s\n' "$(fleet_files_line)"

    # END-TO-END, not a proxy for one, and specifically the probe recovery.md already
    # calibrated: readyConnections from the metrics endpoint. Counting sockets on 7844
    # and reading the log were both tried on `one` and BOTH READ DEAD against a tunnel
    # that was serving normally. A process check would repeat that mistake here — the
    # cloudflared process is running while it retries a tunnel that will never connect.
    printf 'tunnel    : %s\n' "$(tunnel_line)"
    printf 'ansible   : %s\n' "$(d exec "$CONTAINER" ansible --version 2>/dev/null | head -1 || echo 'MISSING')"
    printf 'workspace : %s\n' "$(d exec "$CONTAINER" git -C /workspace log --oneline -1 2>/dev/null || echo 'no git checkout at /workspace')"
}

fleet_files_line() {
    local have=0 n=0 f
    for f in id_ed25519_fleet ssh_config.fleet known_hosts.fleet; do
        n=$((n + 1))
        d exec "$CONTAINER" sh -c "[ -s /run/infra-secrets/$f ]" 2>/dev/null && have=$((have + 1))
    done
    case "$have" in
        0) echo 'no route to zero/one/two — the default, see dev/README.md' ;;
        3) echo 'configured — this container can reach all three hosts' ;;
        *) echo "PARTIAL ($have of 3 files) — expect host key or identity failures" ;;
    esac
}

# ── tunnel ──────────────────────────────────────────────────────────────────
# Three distinguishable answers, because they mean three different things and a single
# up/down would collapse them: not configured at all (normal — the loopback port is the
# way in), configured but not connected (the interesting failure), and serving.
tunnel_line() {
    local host ready
    host="$(d exec "$CONTAINER" printenv DEV_TUNNEL_HOSTNAME 2>/dev/null || true)"
    if [ -z "$host" ]; then
        echo 'off (DEV_TUNNEL_HOSTNAME unset — reached on the loopback port)'
        return
    fi
    ready="$(d exec "$CONTAINER" curl -fsS --max-time 3 http://127.0.0.1:20241/ready 2>/dev/null || true)"
    if [ -z "$ready" ]; then
        echo "$host — metrics endpoint silent, tunnel NOT up (make tunnel-log)"
    elif printf '%s' "$ready" | grep -qE '"readyConnections": *[1-9]'; then
        echo "$host — $(printf '%s' "$ready" | tr -d '\n' | head -c 90)"
    else
        echo "$host — zero ready connections, NOT serving (make tunnel-log)"
    fi
}

# ── fleet ───────────────────────────────────────────────────────────────────
# End-to-end, not a proxy for it. Two questions, in order, because they fail for
# different reasons and the first one's answer tells you how to read the second:
# plain ssh proves the key, the config and the host key; `ansible fleet -m ping`
# additionally proves the inventory, ansible.cfg and the Python interpreter pin.
fleet() {
    if ! d exec "$CONTAINER" sh -c '[ -s /run/infra-secrets/id_ed25519_fleet ]' 2>/dev/null; then
        printf 'No fleet access configured, which is the default.\n\n'
        printf 'This container develops the repo; it does not operate the fleet. Running\n'
        printf 'playbooks against zero, one and two stays on the phone. To change that:\n\n'
        printf '    (not built — see the doc for what would have to be decided first)\n\n'
        printf 'Read docs/management-plane.md § "A control node inside the fleet" first —\n'
        printf 'it is a deferred decision, not an oversight.\n'
        return
    fi
    printf '── ssh, one host at a time ──\n'
    local bad=0
    for h in zero one two; do
        if out=$(d exec "$CONTAINER" ssh -o BatchMode=yes -o ConnectTimeout=10 "$h" hostname 2>&1); then
            printf '  %-5s %s\n' "$h" "$(printf '%s' "$out" | tr -d '\r')"
        else
            printf '  %-5s FAILED: %s\n' "$h" "$(printf '%s' "$out" | head -1)"
            bad=1
        fi
    done
    printf '\n── ansible ──\n'
    d exec "$CONTAINER" ansible fleet -m ping 2>&1 | tail -n 20
    [ "$bad" = 0 ] || printf '\nA host that failed ssh above will fail ansible for the same reason.\nStart there: it is the key, the ssh_config.fleet block, or the host key.\n'
}

# ── verify ──────────────────────────────────────────────────────────────────
# What to run after `up`, in the order that makes a failure legible: the container's
# own state first, then the tools the image is supposed to have gained, then the
# collections against what the repo asks for, then the hop that leaves the box.
verify() {
    status
    printf '\n'
    # A rebuild is where a tool silently fails to arrive. abduco is built from source
    # in a stage of its own and gh is unpacked from a tarball, so those two are the
    # ones to ask: a stage that failed would have failed the build, but a COPY or a tar
    # that landed the wrong path would not.
    printf 'abduco    : %s\n' "$(d exec "$CONTAINER" abduco -v 2>&1 | head -1 || echo 'MISSING — the abduco-build stage did not reach the image')"
    printf 'gh        : %s\n' "$(d exec "$CONTAINER" gh --version 2>&1 | head -1 || echo 'MISSING — the release tarball did not unpack to /usr/local/bin')"
    printf 'screen    : %s\n' "$(d exec "$CONTAINER" screen --version 2>&1 | head -1 || echo 'MISSING')"
    printf 'claude    : %s\n' "$(d exec "$CONTAINER" claude --version 2>&1 | head -1 || echo 'MISSING')"
    printf 'cloudflared: %s\n' "$(d exec "$CONTAINER" cloudflared --version 2>&1 | head -1 || echo 'MISSING — the hash-pinned download did not land')"
    # The one the phone's RemoteCommand names. Absent here and `ssh infra-dev` fails with
    # "Unknown command: in-workspace" from the container's fish — which reads like a
    # broken ssh config and is in fact an image that was never rebuilt. Cheap to check,
    # and it is the check that would have said so.
    printf 'in-workspace: %s\n' "$(d exec "$CONTAINER" sh -c 'command -v in-workspace' 2>/dev/null \
        || echo 'MISSING — this image predates it. Rebuild: make up')"
    printf '\n'
    collections
    printf '\n'
    fleet
}

# ── collections ─────────────────────────────────────────────────────────────
# The Dockerfile names the three collections and so does ansible/requirements.yml,
# because the build context is dev/ and requirements.yml is a directory up. Two lists
# that must agree is a drift waiting to happen, so this compares them rather than
# trusting them — every name requirements.yml asks for must be installed here.
#
# Names only, not versions: requirements.yml states floors (">=13.3.0") and galaxy
# resolves them to whatever satisfied them on build day, so a version comparison would
# report a difference that is not a fault. A collection that is asked for and absent
# is a fault, and that is what this catches.
collections() {
    local want have missing=
    want="$(d exec "$CONTAINER" sh -c \
        "sed -n 's/^  *- *name: *//p' /workspace/ansible/requirements.yml" 2>/dev/null)"
    if [ -z "$want" ]; then
        printf 'colls     : could not read /workspace/ansible/requirements.yml\n'
        return
    fi
    have="$(d exec "$CONTAINER" ansible-galaxy collection list 2>/dev/null)"
    for c in $want; do
        grep -q "^$c " <<<"$have" || missing="$missing $c"
    done
    if [ -n "$missing" ]; then
        printf 'colls     : MISSING —%s\n' "$missing"
        printf '            requirements.yml asks for them and the image does not have\n'
        printf '            them. Add them to dev/Dockerfile and rebuild: make up\n'
    else
        printf 'colls     : all of requirements.yml is installed (%s)\n' \
            "$(tr '\n' ' ' <<<"$want" | sed 's/ *$//')"
    fi
}

# ── boot-log ────────────────────────────────────────────────────────────────
# The START of the log, not the end. `make logs` follows sshd's stream; the lines that
# say why a start went wrong are the entrypoint's, at the very top. ANSI stripped so
# nothing that reached the head can hide them.
boot_log() {
    d logs "$CONTAINER" 2>&1 \
      | sed -E 's/\x1b\][^\x07]*\x07//g; s/\x1b\[[0-9;?]*[ -\/]*[@-~]//g; s/\r//g' \
      | grep -v '^[[:space:]]*$' | head -n "${1:-80}"
}

tunnel_log() {
    d exec "$CONTAINER" sh -c 'tail -n "${1:-60}" "$HOME/.local/share/tunnel.log" 2>/dev/null' \
        -- "${1:-60}" || echo 'no tunnel log — the tunnel has never been started'
}

case "${1:-status}" in
    status)      status ;;
    tunnel-log)  tunnel_log "${2:-60}" ;;
    verify)      verify ;;
    collections) collections ;;
    boot-log)    boot_log "${2:-80}" ;;
    fleet)       fleet ;;
    *) printf 'status.sh: unknown readout "%s" — status | verify | collections | boot-log | fleet | tunnel-log\n' "$1" >&2; exit 1 ;;
esac
