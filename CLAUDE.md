# Working conventions for agents

Human docs live in `docs/` — keep them short, specific, and free of anything inferable.
Put process detail here instead.

## Privileged commands

`gavin` does not use `!` in-session and is not in the `docker` group. Anything needing
`sudo` or the Docker socket is **handed over as a copy-paste block or a reviewable
script**, run in a separate terminal, with the output pasted back.

Never assume a privileged command ran. Verify from its output, or by re-reading state
with unprivileged tools. Prefer writing results to a file the agent can read over
asking for a large paste — but `docker compose config` interpolates `.env`, so those
files contain live secrets: `chmod 600`, keep them outside the repo, delete after.

## Before committing

Two-way secret scan. The name-based one alone is not sufficient:

```sh
git ls-files -z | xargs -0 grep -nEI \
  'PRIVATE_KEY|DISCORD_TOKEN|OPENVPN_PASSWORD|ROOT_PASSWORD|PBKDF2|eyJhIjoi'
git status --porcelain --ignored | grep '\.env$'      # expect: ignored
```

Then value-based: take each live value out of the gitignored `.env` files and grep
every tracked file for it. That catches what a name pattern can't.

## Verifying changes

- Moving a file that must not change: md5 before and after.
- Changing a compose file: diff `docker compose config` output, not the files. Only
  that proves Compose *parses* them identically.
- A check must exclude values it could trivially match. See the `Session\Port` /
  `TORRENTING_PORT` case in `docs/port-forwarding.md` — a bare "did it change" test
  passed on a restart artefact and stopped watching.
- One-shot migration scripts get deleted once run. Leaving an executable in `bin/`
  that tears down live stacks is a foot-gun, and git history keeps it.

## Repo invariants

No `..` in compose files · every compose file declares `name:` · host-specific values
in gitignored `.env` (never `$HOME`) · `/etc` copies under `hosts/<host>/system/` are
read-only references, never applied.
