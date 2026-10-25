# send2ereader

send2ereader on `one`, at **`bookit.gsrpi.uk`**: an e-reader's browser opens the page and
shows a four-character key, and a phone or computer sends a book to that key. Read this to
move it onto its own tunnel, to start it, or to rebuild it.

It has its own tunnel, served by a `cloudflared` sidecar in this compose project, so
nothing listens on `one`. The reasoning is [`docs/decisions.md`](../../docs/decisions.md)
§ *Sidecar, not baked-in*.

| file | what it holds |
|---|---|
| `compose.yaml` | the app, built from the fork, and the sidecar |
| `cloudflared.yml` | the sidecar's routing: `bookit.gsrpi.uk` to the app |
| `edge.yml` | no Access login, and the public name `bookit` |
| `SOURCE` | the fork and the sha `one` builds from |

## Moving it onto its own tunnel, once

Until you run these steps, the container on `one` still publishes port 3001 and `one`'s
host tunnel serves `bookit.gsrpi.uk`. Sending a book fails from step 2 until step 3 ends,
which takes a few minutes.

**1. Dry run, from the control node.** The play pulls `one`'s checkout itself and
refuses if `one` cannot reach this control node's commit.

```fish
cd ~/infra; git pull --ff-only; cd ansible
ansible-playbook playbooks/server-create-deployment-tunnel.yml -e deployment=send2ereader --check -K
```

It should name the hostname `bookit.gsrpi.uk` and access `NONE`. Never add `-l one`; the
play's header says why.

**2. Create the tunnel.**

```fish
ansible-playbook playbooks/server-create-deployment-tunnel.yml -e deployment=send2ereader -K
```

The play creates a tunnel named `send2ereader` and points the existing `bookit` DNS record
at it. From that moment `bookit.gsrpi.uk` shows a Cloudflare error page, because nothing
serves the new tunnel yet. Last, it writes `TUNNEL_ID` and `TUNNEL_CREDENTIALS` into
`.env` on `one`, and sets that file to mode 0600.

**3. Start it, on `one`.**

```fish
ssh one
cd ~/infra/deployments/send2ereader
grep -c '^TUNNEL_' .env       # 2, the play's lines
sudo docker compose up -d     # recreates the app without the port, starts the sidecar
sudo docker compose ps        # both up; the sidecar healthy after about a minute
netstat -tln | grep 3001      # prints nothing
```

Compose reuses the image already built for the app. It rebuilds only with `--build`
(see *Rebuilding* below).

**4. Check it, from the phone.** Open `https://bookit.gsrpi.uk`; the page shows a key.

**5. Install `one`'s host tunnel configuration without `bookit`, from the control node.**

```fish
ansible-playbook playbooks/server-install-system-files.yml -l one -e only=cloudflared-config.yml --check --diff -K
ansible-playbook playbooks/server-install-system-files.yml -l one -e only=cloudflared-config.yml -K
```

Do this only after step 4 works. The diff removes the `bookit` rule and nothing else. You
do not need to restart `one`'s host connector: no DNS record sends `bookit` to it any
more, and it reads the file at its next restart (its autoupdate, every six hours, or a
reboot). Installed before step 2, that next restart would take `bookit` down.

## Starting it after a reboot

Docker restarts both containers on its own (`restart: unless-stopped`). If they are
absent, run step 3's `sudo docker compose up -d`. Compose refuses to start the project
while `.env` lacks `TUNNEL_ID`, and the message names the play that writes it.

## Rebuilding

The app is built from `${SRC_ROOT}/send2ereader` on `one`, which must be checked out at
the sha in `SOURCE`. To deploy a new sha, check it out there, record it in `SOURCE` and
commit, then run `sudo docker compose up -d --build` in this directory on `one`.
`bin/check-sources` reports whether the checkout matches `SOURCE`.

## What not to do

- **Do not put a `ports:` entry back.** The sidecar reaches the app on the project
  network; a published port is a second way in that nothing guards.
- **Do not add `bookit` back to `hosts/one/system/cloudflared-config.yml`.** The DNS
  record points at the sidecar's tunnel, so a rule in `one`'s host tunnel would never
  receive a request, and the next reader of that file would think it did.
