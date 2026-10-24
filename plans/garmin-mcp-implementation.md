# garmin-mcp Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A read-only Garmin Connect MCP server for claude.ai on `one`, deployed in one
command from the phone. The only exception is the interactive Garmin MFA step.

**Architecture:**
- **The stack:** a compose stack, `deployments/garmin-mcp/`, with two services:
  - upstream `gabrielkpo/garmin-mcp-remote`, built from a pinned checkout;
  - a cloudflared sidecar on its own tunnel.
- **The edge** comes from calibre-web's `server-create-stack-tunnel.yml`, unchanged, with
  `access: none`.
- **The new play,** `server-deploy-garmin-mcp.yml`, imports that play, then runs on the host
  it found:
  - fills `.env`;
  - checks out the pinned source;
  - brings the stack up through `community.docker.docker_compose_v2`;
  - proves the result from the phone, end to end.

**Tech Stack:** Docker Compose, Ansible (ansible-core 2.21, community.docker 5.4), cloudflared
2026.10.3, upstream Python (nginx + Starlette shim + Taxuspt/garmin_mcp).

**Spec:** [`plans/garmin-mcp.md`](garmin-mcp.md), approved 2026-10-24. Read it first. Its
§ *The edge* predates calibre-web landing, and Task 2 below supersedes it.

## Global Constraints

- Upstream `https://github.com/gabrielkpo/garmin-mcp-remote.git` at
  `0cf102c139c78287bbb4a7fce5f597b3de3764c8`. Image tag `garmin-mcp-remote:0cf102c`.
- Taxuspt (pinned by upstream's Dockerfile) at `30324f70ccb50c2570126501df17acf0b5572083`.
- **The checkout lives at `$SRC_ROOT/garmin-mcp`**, not `…/garmin-mcp-remote` as the spec has
  it, because `bin/check-sources` looks for `$SRC_ROOT/<stack>` (`bin/check-sources:98`).
- **The sidecar image is calibre-web's exact pin,**
  `cloudflare/cloudflared:2026.10.3@sha256:faa8e0a1475f137c910be6025f43c8e4092fdd35461b31e19fd1390657a1ff39`.
  One version across sidecars.
- **The hostname is `garmin-mcp.gsrpi.uk`.** It is derived by the stack play and written as a
  literal only in `cloudflared.yml`, where the stack play asserts the two match.
- **Read-only:** `GARMIN_ENABLED_TOOLS` is exactly Taxuspt's `READ_ONLY_TOOLS` at the pinned
  sha: 108 names, every one matching `^(get|count|search)_`. `garmin_allowed_writes: []`.
- **Containers** get `mem_limit` 512m (garmin-mcp) and 128m (cloudflared), and calibre-web's
  `x-logging` anchor: `json-file`, `max-size: 10m`, `max-file: "3"`.
- **garmin-mcp hardening:** `security_opt: [no-new-privileges:true]`, `cap_drop: [ALL]`,
  `cap_add: [CHOWN, SETUID, SETGID, DAC_OVERRIDE]`. `DAC_OVERRIDE` is unconditional; the spec
  gives the reason.
- **garmin-mcp environment:** `GARMIN_MCP_STATELESS_HTTP: "true"`.
  - Use **explicit `environment:`, never `env_file:`**, so a `GARMIN_PASSWORD` line in
    `.env` can never reach the container.
- **No `ports:`, no `network_mode: host`**, anywhere in `compose.yaml`.
- **Never committed:** a `docker compose config` dump, and any `.env`. Stubs live in the
  scratchpad only.
- **One implementation commit.** Tasks 1–4 are staged and committed together at the end of
  Task 4, because CLAUDE.md requires a commit to carry its docs. Then the review's fixes go
  in a second commit, and both are pushed together.

## Review Focus

These are the failure modes most likely to bite on the owner's first run that no step below
can exercise from `infra-dev`:

1. **A fresh `one` with no `.env` at all.** The stack play creates `.env` holding only the two
   `TUNNEL_` lines. The garmin play must fill the other four before compose runs, or compose
   stops on the first `:?`. Pinned by the ordering assert, item 4 of Task 3, Step 3.
2. **The owner follows upstream's README and adds `GARMIN_EMAIL`/`GARMIN_PASSWORD` to
   `.env`.** The play stops and names the lines; nothing else happens. Pinned by item 1 of
   Task 3, Step 3.
3. **The tunnel was created seconds ago and DNS has not propagated.** The probes retry; they
   do not fail on the first 530/1033. Pinned by item 6 of Task 3, Step 3: every probe retries
   20 times at a 15 s delay.
4. **A Taxuspt bump adds a tool that breaks the prefix convention.** The probe fails closed
   and names it. Pinned by the derivation check in Task 1, Step 3, which is redone at every
   bump.
5. **`tools/list` comes back as a JSON-RPC error, or as SSE when the probe expected JSON.**
   The probe prints the error body; it does not throw a Jinja traceback. Pinned by the
   fixture test in Task 3, Step 1.

---

### Task 1: The allowlist and the stack files

**Files:**
- Create: `deployments/garmin-mcp/compose.yaml`, `cloudflared.yml`, `edge.yml`, `.env.example`, `SOURCE`
- Create: `hosts/one/garmin-mcp` → `../../deployments/garmin-mcp` (symlink)

**Interfaces:**
- Produces, as the variables compose requires, all `${VAR:?message}`:
  - `SRC_ROOT`, `PUBLIC_BASE_URL`, `MCP_CONSENT_SECRET` and `MCP_BEARER_TOKEN`, which
    Task 3 writes;
  - `TUNNEL_ID` and `TUNNEL_CREDENTIALS`, which the stack play writes.
- Produces service names `garmin-mcp` and `cloudflared`, container names `garmin-mcp` and
  `garmin-mcp-cloudflared`, and the volume `garmin-tokens`.
- Produces `edge.yml` = `access: none`, with no other keys.

- [ ] **Step 1: Get a compose binary that needs no daemon, verified**

```fish
set S /tmp/claude-1001/-workspace/34089ae8-b304-458c-abd7-381d291c4ed6/scratchpad
mkdir -p $S/compose; cd $S/compose
gh release download v5.6.1 -R docker/compose -p docker-compose-linux-aarch64 -p checksums.txt
grep ' \*\?docker-compose-linux-aarch64$' checksums.txt | sha256sum -c -
chmod +x docker-compose-linux-aarch64
```
Expected: `docker-compose-linux-aarch64: OK`.

- [ ] **Step 2: Write the failing check.** A stub `.env` outside the repo, and `config`
  against a directory with no `compose.yaml` yet.

```fish
printf '%s\n' SRC_ROOT=/stub/src PUBLIC_BASE_URL=https://garmin-mcp.gsrpi.uk \
  MCP_CONSENT_SECRET=stubconsentstubconsent MCP_BEARER_TOKEN=stubbearerstubbearer \
  TUNNEL_ID=00000000-0000-0000-0000-000000000000 TUNNEL_CREDENTIALS=/stub/tunnel.json > $S/garmin.env
$S/compose/docker-compose-linux-aarch64 --project-directory /workspace/deployments/garmin-mcp \
  --env-file $S/garmin.env config --quiet
```
Expected: FAIL, no configuration file.

- [ ] **Step 3: Derive the allowlist by reading, never importing, and cross-check it**

Run with `python3 -I` against `$S/gmcp`, the Taxuspt clone already checked out at the pinned
sha. Literal-eval `READ_ONLY_TOOLS`, `ADDITIVE_TOOLS` and `DESTRUCTIVE_TOOLS` from
`src/garmin_mcp/tool_annotations.py`, and collect every name decorated `@app.tool()` across
`src/garmin_mcp/*.py`. Assert all of:
- the read-only set has 108 names, and every one matches `^(get|count|search)_`;
- the read-only set is disjoint from the additive and destructive sets;
- every read-only name is registered as a tool;
- no write name matches that prefix.

Print the sorted names joined by `,`. That string is the value of `GARMIN_ENABLED_TOOLS`.

Expected: all asserts pass and 108 names print.

- [ ] **Step 4: Write the five files and the symlink**
  - **`compose.yaml`:** follow `deployments/calibre-web/compose.yaml` section by section.
    - `name: garmin-mcp`, and the header comments for no `network_mode: host`, literal
      images, and the sidecar being outside 2h.
    - The `garmin-mcp` service:
      - `build: {context: "${SRC_ROOT:?…}/garmin-mcp"}` and
        `image: garmin-mcp-remote:0cf102c`;
      - `restart: unless-stopped`, the `garmin-tokens:/data/garminconnect` volume, and the
        Global Constraints' limits, caps, logging and environment;
      - `GARMIN_ENABLED_TOOLS` as a YAML folded scalar holding Step 3's string.
    - Comments above the allowlist:
      - Step 3's derivation, as the command to rerun at a sha bump;
      - "adding a write tool is one name here plus one in the play's
        `garmin_allowed_writes`";
      - why the environment is explicit and not `env_file`.
    - The `cloudflared` service: calibre-web's, with `calibre-web` replaced by `garmin-mcp`
      in the container name and the `:?` messages.
  - **`cloudflared.yml`:** calibre-web's, with the single rule
    `garmin-mcp.gsrpi.uk → http://garmin-mcp:8080`, then `http_status:404`.
  - **`edge.yml`:** `access: none`, with a comment. claude.ai's connector cannot pass
    Access; the OAuth shim inside the stack is the gate (`docs/decisions.md` § *Sidecar, not
    baked-in*).
  - **`.env.example`:** the six variables, commented out, saying which play writes each. Add
    a paragraph on why there is no Garmin email or password line:
    - `auth_cli.py` prompts for them;
    - upstream's server silently logs in with a password it finds and writes a base64 token
      copy;
    - the play refuses both lines.
  - **`SOURCE`:** `send2ereader/SOURCE`'s two header comment lines, then
    `https://github.com/gabrielkpo/garmin-mcp-remote.git 0cf102c139c78287bbb4a7fce5f597b3de3764c8`.

- [ ] **Step 5: Run the check, and its negatives**

Run Step 2's command again.
Expected: exit 0, no output.

Then confirm the guards fire:
- Remove `MCP_CONSENT_SECRET` from a copy of the stub. Expected: FAIL naming
  `MCP_CONSENT_SECRET`.
- Pipe `config` (not `--quiet`) into
  `grep -cE '^\s+(ports|network_mode|env_file):'`. Expected: `0`.
- Pipe it into `grep -c GARMIN_PASSWORD`. Expected: `0`.

Never write the full `config` output to a file. It interpolates `.env`, stub or not.

- [ ] **Step 6: Run the stack play's own file checks against these files**

Its first play runs on `localhost` and needs no Cloudflare token:

```fish
cd /workspace/ansible
ansible-playbook playbooks/server-create-stack-tunnel.yml -e stack=garmin-mcp --check 2>&1 | grep -E 'routes|placed|edge.yml:|FAILED|fatal'
```
Expected:
- `cloudflared.yml routes garmin-mcp.gsrpi.uk`;
- `placed: […/hosts/one/garmin-mcp]`;
- `edge.yml: {'access': 'none'}`.

The run then fails at the second play, which is unreachable from `infra-dev`. That failure is
expected.

---

### Task 2: Supersede the spec's § *The edge*

**Files:**
- Modify: `plans/garmin-mcp.md`, § *The edge* and step 1 of § *The play*

- [ ] **Step 1: Replace the section with three facts**
  - The edge is `server-create-stack-tunnel.yml` with `stack=garmin-mcp`. It was reviewed
    from this side on 2026-10-24 and landed in `7bda874`.
  - It writes `TUNNEL_ID` and `TUNNEL_CREDENTIALS` into `.env` (creating it at 0600), and
    the credentials to `~/.garmin-mcp-secrets/tunnel.json`, 65532:65532, mode 0600.
  - garmin's play imports it rather than duplicating it.

  Also make two corrections:
  - `garmin-mcp-remote` becomes `garmin-mcp` in the checkout path.
  - The git step's "refuses … a different sha" becomes "refuses a dirty checkout, and moves a
    clean one to the pinned sha". A refusal on any other sha would turn every reviewed bump
    into a manual step.

- [ ] **Step 2: Check**

Run: `grep -nE 'workspace-46|shared tasks file|SRC_ROOT:\?\}/garmin-mcp-remote' plans/garmin-mcp.md`
Expected: no output.

---

### Task 3: `ansible/playbooks/server-deploy-garmin-mcp.yml`

**Files:**
- Create: `ansible/playbooks/server-deploy-garmin-mcp.yml`

**Interfaces:**
- Consumes from the stack play's `add_host`: the group `stack_target`, plus `stack_hostname`
  as a hostvar.
- Relies on the stack play's own check (`server-create-stack-tunnel.yml:283-303`) that the
  host's `compose.yaml`, `edge.yml` and `cloudflared.yml` match the phone's. This play does
  not repeat it.
- Consumes the patterns of `_assert-inventory.yml` and `_cf-api-token.yml`, as the stack play
  uses them.
- Produces the `.env` keys from Task 1, and the vars `garmin_allowed_writes: []`,
  `garmin_read_prefix: '^(get|count|search)_'`, `probe_retries: 20` and `probe_delay: 15`.

**Shape:** two entries.
1. `import_playbook: server-create-stack-tunnel.yml` with `vars: {stack: garmin-mcp}`.
2. A play on `hosts: stack_target`, `gather_facts: false`, whose first task is
   `ansible.builtin.setup` with `gather_subset: ['!all']`. This is the stack play's own
   pattern, at `server-create-stack-tunnel.yml:275`.

**Play vars:**
- `garmin_stack_dir: "{{ ansible_user_dir }}/infra/deployments/garmin-mcp"`
- `garmin_src: "{{ ansible_user_dir }}/src/garmin-mcp"`
- `garmin_source`: the URL and sha, split out of `deployments/garmin-mcp/SOURCE` on the
  control node with `lookup('file')`. This keeps one copy of the sha.
- `garmin_consent_file: "{{ lookup('env', 'HOME') }}/.config/garmin-mcp/consent-secret"`

The header follows the house style:
- what it does and the three commands (`--check`, run, run again after MFA);
- `-K` and why;
- NO `-l`, for the stack play's reason;
- that it starts the stack, and why this play differs from the provision-only plays:
  `management-plane.md` § *`bin/compose` goes, at Phase 3* decided that Ansible drives
  stacks.

- [ ] **Step 1: Write the probe-parse test first.** This is the one expression with real
  logic.

```fish
for b in '{"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"get_stats"}]}}' \
         'event: message
data: {"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"get_stats"},{"name":"delete_activity"}]}}' \
         '{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"nope"}}'
  ansible localhost -m debug -e "body=$b" -a 'msg={{ <EXPR> }}'
end
```
Expected:
- `['get_stats']`;
- `['get_stats', 'delete_activity']`;
- a readable failure naming `nope`, not a traceback.

Then confirm that `select('match', garmin_read_prefix)` with a reject of
`garmin_allowed_writes` leaves `delete_activity` as the only offender in the second case.

- [ ] **Step 2: Write `<EXPR>`, and make the Step 1 runs pass**

It returns the tool-name list:
- if the body stripped of whitespace starts with `{`, `from_json` it;
- otherwise, the first line matching `^data:`, with that prefix removed, then `from_json`;
- then `.result.tools | map(attribute='name') | list`.

Use Jinja `if/else`, not `ternary`: `ternary` evaluates both branches. A body carrying
`error` is caught by an `assert` before this expression runs; that assert prints `error` in
its `fail_msg`.

- [ ] **Step 3: Write the host tasks, in this order**

  1. **Read `.env` and refuse a password.**
     - Slurp `{{ garmin_stack_dir }}/.env`. It is created by the stack play, which just ran.
     - Parse it into a dict, under `no_log`.
     - Assert there is no `GARMIN_EMAIL` and no `GARMIN_PASSWORD` key. The `fail_msg` names
       both, and says the server would log in with them and write a base64 token copy.
  2. **Fill the secrets.** All `no_log`; none runs under `ansible_check_mode`.
     - The consent secret is `lookup('ansible.builtin.password', garmin_consent_file,
       length=48, chars=['hexdigits'])` on the control node. Then `ansible.builtin.file` sets
       mode 0600, `delegate_to: localhost`.
     - `lineinfile` sets `MCP_CONSENT_SECRET` from that file every run, so rotation is
       deleting the phone file.
     - `MCP_BEARER_TOKEN` is set from `lookup('password', '/dev/null length=64
       chars=hexdigits')`, **only when** the key is absent. Rotation is deleting its line.
     - `PUBLIC_BASE_URL=https://{{ stack_hostname }}` and `SRC_ROOT={{ ansible_user_dir }}/src`
       are set every run.
     - Use `create: false`, so a missing `.env` is a failure, not a silent new file.
  3. **The source.**
     - `ansible.builtin.git` with `repo: garmin_source.url`, `dest: garmin_src`,
       `version: garmin_source.sha` and `force: false`. That refuses local modifications and
       moves a clean checkout to the pinned sha.
     - Then `git rev-parse HEAD` must equal `garmin_source.sha`.
  4. **The ordering assert (Review Focus 1).** All six keys exist in `.env`, read back with a
     fresh slurp. Their values stay under `no_log`; only the key names may print. Under
     `--check`, where item 2 wrote nothing, it reports the missing names in a `debug` and
     does not fail.
  5. **Up.** `community.docker.docker_compose_v2` with `project_src: garmin_stack_dir`,
     `build: policy`, `state: present`, `become: true`. It supports `--check`.
  6. **The probes.** Each runs `delegate_to: localhost` and is skipped under
     `ansible_check_mode`. Each has `retries: "{{ probe_retries }}"`,
     `delay: "{{ probe_delay }}"`, `until:` its condition, and `failed_when: false`, followed
     by an `assert` carrying the message.
     - `GET https://{{ stack_hostname }}/healthz` → 200.
     - `GET …/mcp` with no auth → 401.
     - `GET …/.well-known/oauth-protected-resource` → `json.resource ==
       'https://' ~ stack_hostname ~ '/mcp'`.
     - `GET …/readyz` with the bearer → status 200 or 503, `until`
       `json.status != 'pending'`.
       - On `failed`: a `debug` with `changed_when: true` prints the MFA block, then the play
         stops.
       - The block is for fish and a TTY. Line 1 is `ssh -t one`; it is printed as a step,
         not a command to paste with the rest.
       - Then, to paste inside that shell, two commands:
         `cd ~/infra/deployments/garmin-mcp`, then
         `sudo docker compose run --rm garmin-mcp garmin-mcp-auth; and sudo docker compose
         restart garmin-mcp`.
       - Then "re-run this play". The message says `failed` also covers a Garmin 429 and
         expired tokens.
     - `POST …/mcp` with the bearer:
       - headers `Accept: application/json, text/event-stream` and
         `Content-Type: application/json`;
       - body `{"jsonrpc":"2.0","id":1,"method":"tools/list"}`, `return_content: true`;
       - assert there is no `error`, then apply `<EXPR>`;
       - assert that the names rejecting `garmin_read_prefix` and `garmin_allowed_writes` are
         empty, printing the offenders;
       - assert the count equals the number of comma-separated names in `compose.yaml`'s
         `GARMIN_ENABLED_TOOLS`, read on the control node with `from_yaml`. That is the
         single copy of the list, not a second one.
  7. **The record.** `docker stats --no-stream --format '{{ "{{" }}.Name{{ "}}" }}
     {{ "{{" }}.MemUsage{{ "}}" }}' garmin-mcp garmin-mcp-cloudflared`, with `become`. Then a
     summary `debug` (`changed_when: true`):
     - the hostname and the connector URL `https://garmin-mcp.gsrpi.uk/mcp`;
     - "the consent secret is in ~/.config/garmin-mcp/consent-secret on this phone";
     - the served tool count;
     - memory.

- [ ] **Step 4: Verify parse and dry run**

Run:
- `cd /workspace/ansible && ansible-playbook playbooks/server-deploy-garmin-mcp.yml --syntax-check`
  Expected: `playbook: playbooks/server-deploy-garmin-mcp.yml`.
- `ansible-playbook playbooks/server-deploy-garmin-mcp.yml --check 2>&1 | grep -E 'routes|placed|fatal|ERROR'`
  Expected: the stack play's first-play lines as in Task 1, Step 6, then unreachable at
  `one`, and no Jinja or undefined-variable error before that point.

---

### Task 4: Docs, the runbook, and the commit

**Files:**
- Create: `deployments/garmin-mcp/README.md`
- Modify: `docs/decisions.md`, `README.md`, `docs/cloudflare.md`, `docs/management-plane.md`
- Delete: `plans/garmin-mcp-implementation.md` (this file)

- [ ] **Step 1: `deployments/garmin-mcp/README.md`**, shaped like calibre-web's README. It
  covers:
  - what the stack is;
  - the one command, `--check` first;
  - the MFA step, and why it cannot be automated;
  - connecting claude.ai: the URL, leave the OAuth fields blank, paste the consent file;
  - rotation (delete the phone file or the `.env` line, re-run, reconnect);
  - token renewal (~6 months: the same MFA block);
  - adding a write tool (two lists, one commit);
  - a sha bump (redo Task 1, Step 3's derivation; the tag changes; the build follows);
  - what not to do: no `env_file`, no password in `.env`, no `ports:`.

- [ ] **Step 2: `docs/decisions.md`:** two rows, in the table's existing column shape.
  - garmin-mcp on `one`, not `zero` or `two`, with no Access in front. Cite § *Sidecar, not
    baked-in*; do not restate it.
  - Taxuspt read-only over Garmin's Personal API: the coverage reason (set-level strength,
    training status, readiness, race predictions); the revisit trigger (a Personal API
    server that matures and surfaces FIT sets); and the shim findings, kept and deliberately
    not filed upstream (owner, 2026-10-24).

- [ ] **Step 3: The other three docs**
  - **`README.md`:** the fleet table's `one` row gains garmin-mcp; the ports table's `one`
    row says "garmin-mcp: none published, own tunnel".
  - **`docs/cloudflare.md`:** the `garmin-mcp.gsrpi.uk` row, beside calibre-web's, marked
    as its own tunnel with no Access.
  - **`docs/management-plane.md`:**
    - line 524's "would be the second. Not built." becomes "is the second", **once the
      stack exists**;
    - file two items in the phase table: "nothing alerts when garmin-mcp's Garmin tokens
      expire", and "revisit the Personal API backend".

- [ ] **Step 4: Run CLAUDE.md's checks**
  - The two-way secret scan: names, then values from every gitignored `.env`.
  - `git status --porcelain --ignored | grep '\.env$'`. Expected: ignored only.
  - `git diff --cached --stat`. Expected: only the files listed in Tasks 1–4.
  - Delete `$S/garmin.env`.

- [ ] **Step 5: Commit, but do not push yet**

`git rm plans/garmin-mcp-implementation.md`, then one commit. The message is one lowercase
sentence saying what and why, prefixed `garmin-mcp:`, ending with the Co-Authored-By
trailer. `plans/garmin-mcp.md` **stays**: the spec deletes itself once the owner's run
passes the probe.

---

### Task 5: Review, autofix, push

- [ ] **Step 1: A Fable review of the commit.** It reports and does not edit. Give it:
  - the commit;
  - `plans/garmin-mcp.md`;
  - the upstream clone paths;
  - `server-create-stack-tunnel.yml`;
  - this plan's Review Focus as its checklist;
  - the owner's brief: realistic findings only, and flag over-engineering.

- [ ] **Step 2: Verify each finding against the code,** apply the real ones, and rerun the
  affected verification steps above.

- [ ] **Step 3: A second commit saying what was wrong,** then `git push origin main`.
  Confirm `git status -sb` shows no `ahead`.

- [ ] **Step 4: The handover.** Tell the owner:
  - the three phone commands;
  - what was verified here (the compose parse, the play's parse and dry run up to the
    unreachable host, the allowlist, the probe parser);
  - what only their run proves (the aarch64 build, MFA, the probe, memory).
