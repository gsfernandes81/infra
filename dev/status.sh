#!/usr/bin/env bash
# The readouts for one dev container (infra unless CONTAINER says), on the HOST side: what state the container is in, what a
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

CONTAINER="${CONTAINER:-infra}"
DOCKER=(${SUDO:-} docker)

d() { "${DOCKER[@]}" "$@"; }

# The offload loop's age, as a snippet run INSIDE the hub (sh, no bash), shared by both views.
# hub-health holds the hub unhealthy past the same 10 minutes.
OFFLOAD_AGE='f=$HOME/.hub/offload.beat; [ -f "$f" ] || { echo "no pass yet at the hub — make boot-log C=hub"; exit 0; }; a=$(( $(date +%s) - $(stat -c %Y "$f") )); if [ "$a" -le 600 ]; then echo "the hub'"'"'s, last pass $((a / 60))m ago (make offload-log)"; else echo "NO PASS in $((a / 60))m at the hub — its loop has stopped; make boot-log C=hub"; fi'

# ── the hub's own view (make status C=hub) ─────────────────────────────────
# The hub runs no claude, has no workspace and no ansible, so the dev-container lines would
# each read as a fault. These are what the hub is for: its health verdict, which containers
# it serves, its two loops, and its tunnel.
hub_status() {
    printf 'container : %s\n' "$(d inspect -f '{{.Name}} {{.State.Status}} id={{slice .Id 0 12}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}}' dev-hub 2>/dev/null || echo 'absent')"
    printf 'health    : %s\n' "$(d exec dev-hub hub-health 2>/dev/null || true)"
    printf 'serves    : %s\n' "$(d exec dev-hub github-tokens hosts 2>/dev/null || echo 'could not ask the hub')"
    printf 'offloader : %s\n' "$(d exec dev-hub sh -c '[ "${HUB_OFFLOAD:-1}" = 1 ] || { echo "off (HUB_OFFLOAD=$HUB_OFFLOAD)"; exit 0; }; '"$OFFLOAD_AGE" 2>/dev/null || echo 'could not ask the hub')"
    # A pass writes to its log only when a container offloaded or failed, so the newest lines
    # there are the last EVENTFUL pass, which may be long before the last pass. Stamped.
    printf 'passes    : %s\n' 'newest lines of ~/.hub/passes.log (a quiet pass writes none)'
    d exec dev-hub sh -c 'tail -n 3 "$HOME/.hub/passes.log" 2>/dev/null' 2>/dev/null | sed 's/^/            /'
    # Each container's newest line from the broker, then the log's last line if it is hub-wide
    # (no key, GitHub down). The log holds repo and expiry, never a token.
    printf 'tokens    : %s\n' 'newest per container in ~/.hub/github-tokens.log'
    d exec dev-hub sh -c 'l=$HOME/.hub/github-tokens.log; [ -f "$l" ] || { echo "no token pass yet"; exit 0; }; for h in $(github-tokens hosts); do grep " $h: " "$l" | tail -n 1; done; tail -n 1 "$l" | grep -v -E " [a-z0-9-]+: " || true' 2>/dev/null \
        | sed 's/^/            /'
    printf 'sessions  : %s\n' "$(d exec dev-hub claude-sessions --version 2>/dev/null || echo 'no claude-sessions in the hub')"
    printf 'tunnel    : %s\n' "$(tunnel_line)"
}

# ── status ──────────────────────────────────────────────────────────────────
status() {
    [ "$CONTAINER" = dev-hub ] && { hub_status; return; }
    # One read of every process's cmdline, used by the lines below. Straight out of
    # /proc rather than `pgrep`, because procps was not in the image's package list when
    # this was written (it is now, Dockerfile.base): if pgrep is absent, `pgrep … || echo
    # "no daemon"` reports a healthy daemon as missing, and a status line that lies is
    # worse than one that is not there. /proc stays the read with no dependency at all.
    local procs
    procs="$(d exec "$CONTAINER" sh -c \
        'for p in /proc/[0-9]*/cmdline; do tr "\0" " " < "$p" 2>/dev/null; echo; done' 2>/dev/null || true)"

    # Container ID, not StartedAt: StartedAt necessarily changes across a legitimate
    # stop/start, so it cannot tell a cycle from a recreate. The ID can. oom is here
    # because a container's mem_limit, or the pool above it, is the expected way for a
    # limit to be wrong — and Docker's flag can be wrong too: `rc-service devpool show`
    # counts the pool's kills from the kernel.
    printf 'container : %s\n' "$(d inspect -f '{{.Name}} {{.State.Status}} id={{slice .Id 0 12}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}}' "$CONTAINER" 2>/dev/null || echo 'absent')"
    printf 'published : %s\n' "$(d port "$CONTAINER" 2222/tcp 2>/dev/null || echo 'none')"

    # sshd is the container's foreground process, so this line and the container's own
    # status say the same thing from two directions. If they ever disagree, believe
    # this one: a container can be `running` with its payload dead only if something
    # has gone wrong in a way worth seeing spelled out.
    printf 'sshd      : %s\n' "$(grep -q 'sshd' <<<"$procs" \
        && echo 'running in the foreground (the way in)' \
        || echo 'NOT running — nothing to ssh into; see: make boot-log')"

    # The sessions are the work: this is where a claude lives — a zmx session per slot since
    # claude-sessions v0.4.0. Read as the SOCKET DIRECTORY rather than by running `zmx list`,
    # which connects to every session and writes a line into each one's log: a status check
    # should not churn what it reads. One socket, one session. The directory is zmx's own
    # answer (`zmx version` prints it; it is /tmp/zmx-<uid> with no ZMX_DIR set), and zmx
    # creates it just to report it, which is harmless here. A socket can outlive a killed
    # daemon until the next `zmx list` clears it, so this can name one dead session.
    local sessions
    sessions="$(d exec "$CONTAINER" sh -c 'z=$(zmx version 2>/dev/null | sed -n "s/^socket_dir[[:space:]]*//p"); [ -n "$z" ] && find "$z" -maxdepth 1 -type s -printf "%f\n" 2>/dev/null' 2>/dev/null)"
    if [ -n "$sessions" ]; then
        printf 'sessions  : zmx — %s\n' "$(sort <<<"$sessions" | tr '\n' ' ' | sed 's/ *$//')"
    else
        printf 'sessions  : %s\n' 'no zmx sessions (make claude, or ssh in and start one)'
    fi

    # The offloader is excluded by name, or its own argv would read as a claude: its
    # entrypoint loop is a `bash -c` whose arguments name claude-sessions files, forever.
    printf 'claude    : %s\n' "$(grep 'claude' <<<"$procs" \
        | grep -vE 'claude-sessions|/proc/' | grep -q . \
        && echo 'a claude is running in this container' || echo 'no claude running')"

    # The offloader is the HUB's since 2026-10-26: whether this container is one it reaches, and
    # the age of its beat file, which the loop touches after EVERY pass. Not passes.log's age: a
    # pass writes there only when a container offloaded or failed, so a quiet hub would read as
    # stopped. Not $CLAUDE_SESSIONS_HOSTS either: the hub's entrypoint exports that to its own
    # children, and a `docker exec` never sees it; `github-tokens hosts` derives the same list
    # from the HUB_REPO_* names, as the hub's claude-sessions wrapper does. Read by file age, not
    # by matching argv — `pgrep -f` on the loop's own words is the self-match trap CLAUDE.md records.
    printf 'offloader : %s\n' "$(d exec dev-hub sh -c '[ "${HUB_OFFLOAD:-1}" = 1 ] || { echo "off at the hub (HUB_OFFLOAD=$HUB_OFFLOAD)"; exit 0; }; case " $(github-tokens hosts 2>/dev/null) " in *" $1 "*) ;; *) echo "the hub does not reach $1 — no HUB_REPO_* line for it in compose.yaml"; exit 0 ;; esac; '"$OFFLOAD_AGE" _ "$CONTAINER" 2>/dev/null \
        || echo 'could not ask the hub — is it up? (make status C=hub)')"

    # `claude auth status`, not "is there a credentials file" — a file holding empty
    # tokens exists and reports logged out, so the file's presence proves nothing.
    printf 'auth      : %s\n' "$(login_line)"

    # The two files that decide whether this container can reach the fleet at all.
    # Named separately because they fail differently: no ssh_config.fleet is "unknown
    # host zero", no known_hosts.fleet is a host key failure that reads like a refused
    # connection. Neither is written by anything in the repo today.
    # Absent is the DEFAULT here, not a fault. Fleet access is opt-in
    # (INFRA_DEV_FLEET=1) because it makes this a control node running on a box it
    # controls, which the owner decided against on 2026-10-25. So the line says
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

# ── the hub's reach into this container ─────────────────────────────────────
hub_line() {
    local key here there
    if d exec "$CONTAINER" sh -c 'grep -q "^restrict,pty ssh-" "$HOME/.ssh/authorized_keys.hub"' 2>/dev/null; then
        key='key authorised'
    else
        key='hub key NOT authorised: is the hub up? make status C=hub, then make restart'
    fi
    here="$(d exec "$CONTAINER" claude-sessions --version 2>/dev/null || echo 'no claude-sessions')"
    there="$(d exec dev-hub claude-sessions --version 2>/dev/null || echo 'no hub')"
    echo "$key; $here here, $there at the hub"
}

# Which Claude login this container is on (compose.yaml § THE CLAUDE LOGIN), and whether it is in.
login_dir() { d exec "$CONTAINER" printenv CLAUDE_SECURESTORAGE_CONFIG_DIR 2>/dev/null; }
logged_in() { d exec "$@" "$CONTAINER" claude auth status 2>/dev/null | grep -q '"loggedIn": *true'; }
login_line() {
    local dir which
    dir="$(login_dir)"
    case "$dir" in
        /home/dev/.claude-logins/true)  which='the shared login' ;;
        /home/dev/.claude-logins/false) which='its own login' ;;
        '')                             which='its own login (no switch: compose.yaml predates it)' ;;
        *)                              which="a login in $dir, which is neither setting (dev/.env.example)" ;;
    esac
    if logged_in; then echo "claude logged in — $which"
    elif [ "$dir" = /home/dev/.claude-logins/true ]; then echo "claude NOT logged in — $which; make login in any one container logs in every one"
    else echo "claude NOT logged in — $which; run: make login"; fi
}

# THE PROOF THAT CLAUDE CODE STILL READS CLAUDE_SECURESTORAGE_CONFIG_DIR, which is undocumented and
# could be renamed by any update. Asked twice: as configured, then pointed at an empty directory.
# Honoured, the second reads logged out; ignored, both read whatever ~/.claude holds, and the
# container is quietly on a different login from the others.
login_dir_line() {
    local dir tmp
    dir="$(login_dir)"
    logged_in || { echo "cannot tell while logged out (make login)"; return; }
    tmp="$(d exec "$CONTAINER" mktemp -d 2>/dev/null)" || { echo 'could not ask the container'; return; }
    if logged_in -e CLAUDE_SECURESTORAGE_CONFIG_DIR="$tmp"; then
        echo "NOT HONOURED — this claude ignores CLAUDE_SECURESTORAGE_CONFIG_DIR and is on ~/.claude's login, not ${dir:-the configured one} (decisions.md, the shared login)"
    else
        echo "honoured — the login is read from ${dir:-~/.claude}"
    fi
    d exec "$CONTAINER" rm -rf "$tmp" 2>/dev/null
}

# The hub's token for this container, by what the broker wrote beside it (never the token).
github_line() {
    d exec "$CONTAINER" sh -c '
        if [ ! -s /run/github/token ]; then echo "NO hub token — nothing here reaches GitHub; ~/.hub/github-tokens.log in the hub says why"
        else sed -n "s/.*\"repo\": \"\([^\"]*\)\".*\"expires_at\": \"\([^\"]*\)\".*/the hub'"'"'s token for \1, until \2/p" /run/github/meta.json; fi' 2>/dev/null \
        || echo 'could not ask the container'
}

# ── tunnel ──────────────────────────────────────────────────────────────────
# The hub's sidecar since 2026-10-26 — no dev container has a tunnel of its own. Its
# healthcheck is the probe recovery.md calibrated (/ready, readyConnections >= 1), so the line
# reads Docker's verdict on it rather than probing again: not running (the `tunnel` profile is
# off, or it died), running and unhealthy (the interesting failure), or healthy.
tunnel_line() {
    local st
    st="$(d inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' dev-cloudflared 2>/dev/null || true)"
    case "$st" in
        '')            echo 'no dev-cloudflared — the tunnel profile is off (COMPOSE_PROFILES in .env)' ;;
        'running healthy') echo 'the hub'"'"'s, serving dev — ready connections >= 1' ;;
        running*)      echo "the hub's, $st — NOT serving yet (make tunnel-log)" ;;
        *)             echo "the hub's, $st (make tunnel-log)" ;;
    esac
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
        printf 'playbooks against zero, one and two stays on the phone, by the owner'"'"'s\n'
        printf 'decision of 2026-10-25: docs/management-plane.md § "A control node inside the fleet".\n'
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
    # A rebuild is where a tool silently fails to arrive: gh is unpacked from a tarball
    # and the language servers are hash-checked downloads, so a build that succeeded can
    # still have landed one in the wrong path. These lines ask the container instead of
    # trusting the build.
    #
    # `tool` EXISTS BECAUSE THE FALLBACK IT REPLACES COULD NOT FIRE. Every one of these
    # was `$(… | head -1 || echo 'MISSING — …')`, and a `||` after a pipeline tests the
    # LAST command in it: `head` succeeds on empty input, so the message naming the cause
    # was unreachable in all five. Nothing looked wrong, because what printed instead was
    # docker's own "executable file not found", which reads like an answer. CLAUDE.md
    # § *Shell traps* has the general form; this is that trap sitting in the file that
    # exists to tell you the truth about the container.
    #
    # `command -v` RUNS FIRST, IN THE SAME EXEC, and that is what makes the fallback
    # mean what it says. Exit status cannot answer "is it in the image": `abduco -v`, which
    # this image carried until 2026-10-06, was the kind of tool that prints its version and
    # exits non-zero, and a readout calling
    # that MISSING would be the other failure this repo keeps recording — a check wrong
    # about a healthy system. So: binary absent, nothing is run and nothing is printed,
    # and the message fires. Binary present, its own first line is printed whatever it
    # exits with. One exec either way.
    tool() {
        local label=$1 fallback=$2; shift 2
        local out
        out="$(d exec "$CONTAINER" sh -c 'command -v "$1" >/dev/null 2>&1 || exit 0; exec "$@"' \
                 sh "$@" 2>&1 | head -1 | tr -s '\t' ' ')"
        printf '%-10s: %s\n' "$label" "${out:-MISSING — $fallback}"
    }

    # The libc first, because everything under it links against this one. It is here
    # because the image was moved to Debian trixie on 2026-09-21 for a floor of 2.39 —
    # a floor nobody can see from outside the container, and a `FROM` line that gets
    # reverted by a careless edit would show up nowhere else in this readout.
    tool libc   'no ldd, which a Debian image always has' ldd --version
    tool zmx    'the pinned zmx tarball did not reach /usr/local/bin' zmx version
    tool gh     'the release tarball did not unpack to /usr/local/bin' gh --version
    tool screen 'no screen in the image' screen --version
    tool claude 'no claude in the image at all — not an update that failed' claude --version
    # The version above is not what a rebuild landed any more — Claude Code updates
    # itself in place, so it is whatever this container has reached by now. THIS line is
    # the one that says whether it still can.
    #
    # AND IT DELIBERATELY DOES NOT READ `Auto-updates:`, WHICH IS THE OBVIOUS FIELD AND
    # THE WRONG ONE. Measured 2026-09-21 against Claude Code 2.1.278, both ways round:
    # with the npm prefix owned by the account that runs claude, and with it owned by
    # root as the old image had it, `claude doctor` prints `Auto-updates: enabled` in
    # BOTH cases — that field reports the DISABLE_AUTOUPDATER setting and nothing about
    # whether an update can land. The difference between the two runs was a warning,
    # `Can't auto-update: npm global folder isn't writable`, and that string is
    # therefore what this looks for. A check calibrated against a known-good container
    # only would have passed for the wrong reason on a container that could not update
    # at all, which is the failure this repo keeps re-learning.
    #
    # `Last update attempt` is the corroboration: `success -> <version> (<date>)` is an
    # update that actually happened in this container, which no amount of reading
    # settings can fake.
    local doctor autoupdate blocked attempt channel
    doctor="$(d exec "$CONTAINER" sh -c 'timeout 30 claude doctor 2>/dev/null' 2>/dev/null)"
    autoupdate="$(printf '%s\n' "$doctor" | sed -n 's/^Auto-updates: *//p' | head -1)"
    blocked="$(printf '%s\n' "$doctor" | grep -o "Can't auto-update.*" | head -1)"
    attempt="$(printf '%s\n' "$doctor" | sed -n 's/^Last update attempt: *//p' | head -1)"
    # The channel, which the image's managed settings put on `stable` (2026-10-07); `latest`
    # here means an image from before that, or a settings file Claude Code ignored.
    channel="$(printf '%s\n' "$doctor" | sed -n 's/^Auto-update channel: *//p' | head -1)"
    if [ -z "$doctor" ]; then
        printf 'autoupdate: %s\n' 'could not read `claude doctor` — run it in the container'
    elif [ -n "$blocked" ]; then
        printf 'autoupdate: %s\n' "BLOCKED — $blocked (see dev/README.md)"
    else
        printf 'autoupdate: %s\n' "$autoupdate, ${channel:-unknown} channel, nothing blocking it; last attempt: ${attempt:-unknown}"
    fi
    # AGENT VIEW OFF, PRINTED AS TWO SWITCHES rather than one verdict. The managed
    # settings file is the authority — no project or user settings file can override it —
    # and the env var is the belt-and-braces, checked FIRST by the binary, before settings
    # are loaded at all.
    #
    # THE FILE IS PARSED, NOT GREPPED, and that is a fix rather than a flourish. The first
    # version flattened the file and looked for the substring `"disableAgentView":true`,
    # which reads "off" for a file truncated anywhere after the word `true` — no closing
    # brace, so Claude Code's own JSON parse fails, it ignores the whole file, and the view
    # is ON while this line says it is off. It also read "off" for the key nested under
    # some other object, where it means nothing, and read "not off" for a tab after the
    # colon, which is valid JSON the binary accepts. A substring test cannot answer a
    # question about JSON. python3 is in the image — the base is python:3.13-slim-trixie —
    # so the check asks the same question the binary asks.
    #
    # `is True`, not truthiness: the binary tests `settings.disableAgentView === true`, so
    # the string "true" and the number 1 do NOT turn the view off, and a readout that
    # accepted them would be wrong in the direction that matters.
    #
    # THE ENV VAR IS READ FROM THE CONTAINER, not from the image — `docker exec` inherits
    # the container's whole Config.Env, which is the image's ENV plus anything the child's
    # compose `environment:` or `env_file` added. That is the right scope: it is what a
    # session in there will actually see. The message says "in this container" rather than
    # blaming the image, because a child can blank it.
    #
    # `2>&1` on the file read is deliberate: python's own message is the answer, and so is
    # docker's when the container is not running — a real cause beats a guessed one. The
    # `:-` fallback below is for the case where docker says nothing at all.
    local agentview_file agentview_env
    agentview_file="$(d exec "$CONTAINER" python3 -c '
import json, sys
p = "/etc/claude-code/managed-settings.json"
try:
    v = json.load(open(p)).get("disableAgentView")
except FileNotFoundError:
    sys.exit("NO " + p + " — this image predates it (rebuild: make up)")
except ValueError as e:
    sys.exit("NOT VALID JSON, so Claude Code ignores the whole file — %s" % e)
except OSError as e:
    sys.exit("UNREADABLE — %s" % e)
print("managed settings say off" if v is True else
      "PRESENT BUT NOT OFF — disableAgentView is %r, and the binary wants exactly true" % (v,))
' 2>&1)"
    agentview_env="$(d exec "$CONTAINER" sh -c 'printf %s "${CLAUDE_CODE_DISABLE_AGENT_VIEW-}"' 2>/dev/null)"
    printf 'agentview : %s; env=%s\n' \
        "${agentview_file:-could not ask the container — see the container line above}" \
        "${agentview_env:-UNSET in this container — the image should set it to 1}"
    # The starting permission mode every session gets from the same file (base 2026.10.29.1).
    # Parsed for the reasons above. A default only: Shift+Tab and --permission-mode still win.
    printf 'permmode  : %s\n' "$(d exec "$CONTAINER" python3 -c '
import json, sys
p = "/etc/claude-code/managed-settings.json"
try:
    v = (json.load(open(p)).get("permissions") or {}).get("defaultMode")
except FileNotFoundError:
    sys.exit("NO " + p)
except ValueError as e:
    sys.exit("NOT VALID JSON, so Claude Code ignores the whole file — %s" % e)
except OSError as e:
    sys.exit("UNREADABLE — %s" % e)
print("sessions start in %s mode" % v if v else
      "NOT SET — sessions start in default mode and ask (a base before 2026.10.29.1)")
' 2>&1 || true)"
    # The three names claude-sessions (v0.3.8+) sets on every slot's claude so it scrolls in
    # the terminal's own buffer. They come from inside Claude Code's binary, and Claude Code
    # updates itself in a running container — so a rename would leave the variables set,
    # read by nothing, and scrolling quietly back to round trips. Counted in the binary the
    # container runs right now, WORD-BOUNDED: the binary also holds
    # CLAUDE_CODE_DISABLE_MOUSE_CLICKS, which an unanchored match counts as MOUSE, so a
    # rename of MOUSE alone would still have read 3 of 3. Calibrated 2026-10-04 on 2.1.289:
    # -w finds all three, and finds nothing in a line holding only the _CLICKS name. This
    # proves a name is PRESENT, not that it is read — each also sits in an allowlist and a
    # string table — which is as far as a strings check goes; fewer than three is the alarm.
    printf 'scrollvars: %s\n' "$(d exec "$CONTAINER" sh -c 'c=$(command -v claude) || { echo "no claude on PATH"; exit 0; }; b=$(readlink -f "$c"); v=$(claude --version 2>/dev/null | cut -d" " -f1); n=$(grep -aowE "CLAUDE_CODE_DISABLE_(ALTERNATE_SCREEN|MOUSE|VIRTUAL_SCROLL)" "$b" | sort -u | wc -l); if [ "$n" -eq 3 ]; then echo "3 of 3 names present in $v"; else echo "ONLY $n of 3 names present in $v — renamed, or the binary is no longer plain text; tell claude-sessions"; fi' 2>/dev/null \
        || echo 'could not ask the container')"
    # No `bgtasks` line since claude-sessions v0.4.7: no offload rule reads Claude Code any
    # more, so no field in its binary is load-bearing for the offloader (the timer tools'
    # names, claude-sessions#13, were never added for the same reason).
    tool sessions 'no claude-sessions — the hub'"'"'s volume is not mounted at /opt/claude-sessions' claude-sessions --version
    # Unpinned (the latest at the base's build), so this is the only readout of which one a
    # container has once CI's log has expired. MISSING is also what a base built with
    # CRUSH_VERSION=none looks like.
    tool crush 'no crush — a base before 2026.10.11, or one built with CRUSH_VERSION=none' crush --version
    tool jcode 'no jcode — a base before 2026.10.16' jcode --version
    # The hooks that feed claude-sessions, read the way Claude Code reads them: parsed, and
    # as `dev`, because a file that is malformed or unreadable to the session's account is
    # ignored whole and silently — sessions start with no hooks. Whether they actually FIRE
    # is a different question, answered by `make sessions` ("events: none seen"). The status
    # line the same file installs (v0.4.5) is named after them when it is there.
    local hooks_file
    hooks_file="$(d exec "$CONTAINER" python3 -c '
import json, sys
p = "/etc/claude-code/managed-settings.d/claude-sessions.json"
try:
    f = json.load(open(p))
    h = f.get("hooks") or {}
    s = (f.get("statusLine") or {}).get("command")
except FileNotFoundError:
    sys.exit("NO " + p + " — this image predates it (rebuild: make up)")
except ValueError as e:
    sys.exit("NOT VALID JSON, so Claude Code ignores the whole file — %s" % e)
except OSError as e:
    sys.exit("UNREADABLE as dev, so sessions start with no hooks — %s" % e)
print((" ".join(sorted(h)) if h else "PRESENT BUT EMPTY — no hooks in it")
      + ("; status line: " + s if s else ""))
' 2>&1)"
    printf 'hooks     : %s\n' "${hooks_file:-could not ask the container — see the container line above}"
    # The keep-alive skill (claude-sessions v0.4.7): the only thing that tells claude to hold
    # its slot through a quiet wait, now that the offloader reads nothing from Claude Code.
    # The entrypoint writes it to the config volume at every start; this compares it with what
    # the pinned binary prints, so a missing, stale or hand-edited copy says so here rather
    # than as a CI poll offloaded mid-wait. Whether Claude Code still FINDS skills there is
    # not something a file check can answer — `/skills` in a claude is.
    printf 'skill     : %s\n' "$(d exec "$CONTAINER" sh -c 'f="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/keepalive/SKILL.md"; if [ ! -f "$f" ]; then echo "NO $f — claude will not ask for time before a quiet wait (boot-log says why)"; elif claude-sessions skill 2>/dev/null | cmp -s - "$f"; then echo "keepalive, matching claude-sessions $(claude-sessions --version | cut -d" " -f2)"; else echo "$f DIFFERS from what claude-sessions prints — restart the container to rewrite it"; fi' 2>/dev/null \
        || echo 'could not ask the container')"
    # `ssh <c> in-workspace <cmd>` and `ssh -t <c> in-workspace` name it; an image without
    # it answers "in-workspace: not found" from the login shell.
    printf 'in-workspace: %s\n' "$(d exec "$CONTAINER" sh -c 'command -v in-workspace' 2>/dev/null \
        || echo 'MISSING — this image predates it. Rebuild: make up')"
    # What sshd forces, read the way sshd reads it (`sshd -T`, `-C user=dev` taking any Match
    # for this account into the answer), from the one config it runs since 2026-10-27. The door
    # is /usr/local/bin/dev-door — a login shell in /workspace, and a forwarded command as
    # given; the menu is the hub's.
    #
    # The hub's reach into this container: its key authorised (restrict,pty), and the binary
    # here the one the hub installed — the same bytes as the hub's own, since this container
    # runs it from the hub's volume.
    printf 'hub       : %s\n' "$(hub_line)"
    printf 'hub health: %s\n' "$(d exec dev-hub hub-health 2>&1 || true)"
    printf 'github    : %s\n' "$(github_line)"
    printf 'login dir : %s\n' "$(login_dir_line)"
    printf 'door      : %s\n' "$(d exec "$CONTAINER" sh -c '/usr/sbin/sshd -T -C user=dev,host=localhost,addr=127.0.0.1 -f /home/dev/sshd_config 2>/dev/null | sed -n "s/^forcecommand //p"' 2>/dev/null \
        | grep . || echo 'could not ask sshd')"
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

case "${1:-status}" in
    status)      status ;;
    verify)      verify ;;
    collections) collections ;;
    boot-log)    boot_log "${2:-80}" ;;
    fleet)       fleet ;;
    *) printf 'status.sh: unknown readout "%s" — status | verify | collections | boot-log | fleet\n' "$1" >&2; exit 1 ;;
esac
