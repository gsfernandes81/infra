# calibre-web

Calibre-Web on `one`, at **`calibre-web.gsrpi.uk`**: the Calibre library on the web, and the
server a Kobo syncs from. It has its own tunnel, run by a `cloudflared` sidecar in this
compose project, so nothing listens on `one` and `one`'s host tunnel is untouched. The
reasoning is [`docs/decisions.md`](../../docs/decisions.md) § *Sidecar, not baked-in*.

| | |
|---|---|
| `compose.yaml` | the app and the sidecar; images pinned by tag and digest; no `ports:` |
| `cloudflared.yml` | the sidecar's ingress — this file **is** the routing |
| `edge.yml` | Access login on the whole hostname, except `/kobo/` |
| `.env.example` | copied to `.env` on `one` at step 1, **before** the play, which then appends the two tunnel lines |

## What the Kobo sync does, and does not do

- **Books go one way: server → Kobo.** Nothing on the Kobo is uploaded — not sideloaded
  books, not what `send2ereader` delivered. Reading status and stats come back.
- **Deleting a book on the server leaves it on the Kobo.** *Archive* it, then sync.
- **Store purchases survive only with "Proxy unknown requests to Kobo Store" on.**
- **PDFs never sync to a Kobo.** EPUB is converted to KEPUB on the fly by `kepubify`,
  which the image carries.
- **There is no other conversion** (MOBI, AZW3 → EPUB) on this stack, deliberately.
  It works on arm64 if it is ever wanted — the way to add it is a derived image with
  Calibre's arm64 tarball, hash-pinned, not the `DOCKER_MODS` line, which installs on
  every start. The 512 MB cap is already sized with that in mind.

## Setting it up

In order. Every privileged step is a block for **`ssh one` first, then paste inside**,
written for fish. Nothing here restarts anything already running on `one`.

### 1. The checkout on `one`, `.env`, and the space

```fish
cd ~/infra; git pull --ff-only
cd deployments/calibre-web
cp -n .env.example .env; chmod 600 .env    # -n: never over an .env the play already wrote to
id                                         # PUID and PGID are these; edit .env and set them
df -h /media/torrents                      # the array; the library will share it
```

`.env` is made **now**, not after the play: the play appends `TUNNEL_ID` and
`TUNNEL_CREDENTIALS` to whatever is there, and a later `cp` would replace those lines.

On the machine that has the library now: `du -sh "<path to Calibre Library>"`. If it is
anywhere near the free space, stop here — torrents live on the same disk.

### 2. Storage — two subvolumes, behind the mount guards

Named the way this array's subvolumes are: **`media-calibre-<name>` at the top level,
mounted at `/media/calibre/<name>`**.

| Subvolume | Mountpoint | Holds |
|---|---|---|
| `media-calibre-library` | `/media/calibre/library` | the Calibre library — `metadata.db` and every book |
| `media-calibre-config` | `/media/calibre/config` | Calibre-Web's own state — users, settings, Kobo sync tokens |

The same two guard layers as every other `/media` mount (`CLAUDE.md` § *Mount guards*):
`nofail` in fstab, and `chattr +i` on each bare mountpoint, so a missing array can never be
written into. `hosts/one/system/fstab` already carries both lines, by `subvol=` name.
`/media/calibre` itself is a plain directory on the root filesystem and stays writable — it
is never mounted on and nothing writes into it, and leaving it mutable is what lets a third
`media-calibre-*` be added beside these later.

```fish
cd ~/infra                                         # step 1 left you in deployments/calibre-web
sudo mount /mnt                                    # the array's top level (noauto in fstab)
sudo btrfs subvolume get-default /mnt              # must say ID 5 — or /mnt is not the top level,
                                                   # and subvol= in fstab would not find these
sudo btrfs subvolume create /mnt/media-calibre-library
sudo btrfs subvolume create /mnt/media-calibre-config
sudo umount /mnt

sudo mkdir -p /media/calibre                       # the parent may exist; the mountpoints must not:
sudo mkdir /media/calibre/library /media/calibre/config   # a failure here means a bare dir is already
                                                   # there — check it is empty (ls -A) before going on,
                                                   # or +i would freeze whatever got written into it
grep -E '^CALIBRE_' deployments/calibre-web/.env  # must read /media/calibre/library and /media/calibre/config;
                                                   # an .env copied before 2026-10-24 has the old paths, and
                                                   # Docker would create those itself, unguarded, on the SD card
sudo chattr +i /media/calibre/library /media/calibre/config
sudo touch /media/calibre/library/x; and echo 'GUARD FAILED — stop'   # both must say
sudo touch /media/calibre/config/x; and echo 'GUARD FAILED — stop'    # Operation not permitted

bin/install-system-file fstab                      # dry run: the diff is the two new lines, nothing else
sudo bin/install-system-file fstab --commit --allow-content-change
sudo mount /media/calibre/library; sudo mount /media/calibre/config
sudo chown (id -u):(id -g) /media/calibre/library /media/calibre/config
sudo bin/check-mount-guards                        # all six /media mounts: nofail and +i
```

### 3. The library

**Close Calibre first** — `metadata.db` is SQLite, and a copy taken mid-write is a copy of
a half-written change. In Calibre, *Library → Library maintenance → Check library* and
fix what it reports; Calibre-Web has no repair of its own. Then, from that machine:

```fish
rsync -a --info=progress2 "<path to Calibre Library>/" one:/media/calibre/library/
rsync -a --checksum --dry-run --itemize-changes "<path to Calibre Library>/" one:/media/calibre/library/
```

The second command must print **nothing** — that is the proof the copy is byte-identical.
The whole folder goes, not just `metadata.db`: the database points at the files by path
relative to it. Your desktop copy is untouched; after this, **the server copy is the
library** — keep the desktop one as a backup, and do not edit both.

*No library yet?* Calibre-Web ships an empty one: `library/metadata.db` at the release this
image is (`0.6.27`) — copy it into `/media/calibre/library` instead.

### 4. The tunnel and the login — from the control node

```fish
cd ~/infra; git pull --ff-only; cd ansible
ansible-playbook playbooks/server-create-stack-tunnel.yml -e stack=calibre-web --check -K
ansible-playbook playbooks/server-create-stack-tunnel.yml -e stack=calibre-web -K
```

It needs `~/.config/cloudflare/access-emails` on the control node (who may log in, one
address per line) and prints how to make it if it is missing — and, **once**, a sixth
permission on the control node's API token: *Zone → Transform Rules → Edit* (My Profile →
API Tokens → edit the token, add the row). That is for the one request-header rule below;
without it the play stops and says so. It makes the tunnel, the CNAME, the tunnel
credentials file (on `one`, outside the checkout, owned by the sidecar's uid), the Access
login, the `/kobo/` bypass, and a Cloudflare rule setting `X-Scheme: https` on requests to
this hostname — see step 6 for why. It then **proves, before anything is started**, that
`/` asks for a login and `/kobo/` does not — calibrated first against `torrents.gsrpi.uk`
— and only then writes `TUNNEL_ID` and `TUNNEL_CREDENTIALS` into `.env` on `one`. So a run
that fails part way leaves a stack that **cannot** start: compose refuses without those
two lines. A fresh hostname can take a minute to resolve; if the probe gives up on that,
re-run.

It refuses, rather than guesses, when: `one` has not pulled the same commit as the control
node; an Access application on this hostname is not one `edge.yml` asks for (left over
from an earlier `edge.yml`); or a tunnel named `calibre-web` exists with no tunnel
credentials file on `one`. Each message says what to do. Never add `-l one` — see the
play's header.

### 5. Start it — on `one`

```fish
cd ~/infra/deployments/calibre-web
grep -c '^TUNNEL_' .env                            # 2 — the play's lines; PUID/PGID set at step 1
grep -o memory /sys/fs/cgroup/cgroup.controllers   # must print `memory`, or mem_limit is ignored
sudo docker compose up -d
sudo docker compose ps                             # both up; the sidecar healthy within a minute
sudo docker inspect -f '{{.Name}} {{.HostConfig.Memory}}' calibre-web calibre-web-cloudflared
                                                   # 536870912 and 134217728, not 0
```

### 6. Calibre-Web itself — in a browser

Log in through Access, then as `admin` / `admin123`, and **change that password first**.

- Database location: `/books`.
- *Admin → Edit Basic Configuration → Feature Configuration*: **Enable Kobo sync**, **Proxy
  unknown requests to Kobo Store**, and **Server External Port = `443`**. Without the port,
  the Kobo is handed download links ending in `:8083` and the sync dies half way.
  The port alone is not enough behind this tunnel: Calibre-Web takes the scheme for those
  links only from an `X-Scheme` header (`cps/reverseproxy.py`), which Cloudflare does not
  send, so without the step-4 rule the links read `http://calibre-web.gsrpi.uk:443/…` and
  every book download fails while the library itself syncs (upstream: calibre-web#3595).
- *External binaries*: kepubify at `/usr/bin/kepubify`.
- Make a shelf (say *Kobo*), then in your user profile tick **Sync only books in selected
  shelves with Kobo** — **before the first sync**. Turned on later, it archives everything
  that was synced and is not on a shelf. With a migrated library, the default would send
  every EPUB you own, and a big first sync can time out.
- Your profile shows the Kobo sync URL. Copy it.

### 7. The Kobo

Plug it in. **Copy the whole drive to a computer first, the hidden `.kobo` folder
included** — `KoboReader.sqlite` is the device's own record of its library and reading
positions, and that copy is the way back.

In `.kobo/Kobo/Kobo eReader.conf`, under `[OneStoreServices]`, keep the old `api_endpoint=`
line somewhere and set it to the sync URL. Eject, then sync. A book that was already
sideloaded *and* is on a synced shelf will appear twice; delete the sideloaded one.

### 8. Record it

From the control node: `ansible-playbook playbooks/server-generate-fleet-inventory.yml`, and commit
`docs/fleet-inventory.md` — the two containers should appear with nothing published.

## Day two

- **Is the tunnel up?** `sudo docker inspect -f '{{.State.Health.Status}}' calibre-web-cloudflared`.
- **A version bump** — either image — is an edit to `compose.yaml` (tag *and* digest), a
  commit, `git pull` on `one`, `sudo docker compose up -d`. The sidecar does not follow the
  fleet's staggered cloudflared updates.
- **Who may log in** is `~/.config/cloudflare/access-emails` on the control node; edit it and
  re-run step 4's play. It replaces the policy's list; it does not add to it.
- **Lost or leaked tunnel credentials file:** in this order — `sudo docker compose stop
  cloudflared` (a tunnel with a live connection cannot be deleted), move
  `~/.calibre-web-secrets/tunnel.json` aside, delete the tunnel in the dashboard
  (*Networks → Tunnels*), re-run step 4, then `sudo docker compose up -d`. That `up -d`
  **recreates** the sidecar on purpose: `TUNNEL_ID` is in its `command:`, and a
  `stop`/`start` would keep the old id. It is the one place here where `up -d` is right.
