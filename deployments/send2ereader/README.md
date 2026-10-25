# send2ereader

send2ereader on `one`, at **`bookit.gsrpi.uk`**: an e-reader's browser opens the page and
shows a four-character key, and a phone or computer sends a book to that key. Read this to
deploy it, to start it after a reboot, or to move it to a new version.

Kobo conversion (Kepubify) works on `one`, tested live on 2026-10-25. Kindle conversion
does not: KindleGen was only ever built for x86 and the arm64 image leaves it out, so a
Kindle gets an EPUB as it is.

It has its own tunnel, served by a `cloudflared` sidecar in this compose project, so
nothing listens on `one`. The reasoning is [`docs/decisions.md`](../../docs/decisions.md)
§ *Sidecar, not baked-in*.

| file | what it holds |
|---|---|
| `compose.yaml` | the app, the fork's CI-built image pinned by tag and digest, and the sidecar |
| `cloudflared.yml` | the sidecar's routing: `bookit.gsrpi.uk` to the app |
| `edge.yml` | no Access login, and the public name `bookit` |

## Deploying it, from the control node

```fish
cd ~/infra; git pull --ff-only; cd ansible
ansible-playbook playbooks/server-deploy-send2ereader.yml --check -K
ansible-playbook playbooks/server-deploy-send2ereader.yml -K
```

The dry run proves the API token, `one`'s checkout of this repo, and that `one` can fetch
the pinned image from ghcr, and changes nothing. It should name the hostname `bookit.gsrpi.uk`
and access `NONE`. Never add `-l one`; the play's header says why.

A real run does this, in order:

1. pulls `one`'s checkout of this repo to the control node's commit;
2. makes or finds the tunnel `send2ereader` and points the `bookit` DNS record at it;
3. writes `TUNNEL_ID` and `TUNNEL_CREDENTIALS` into `.env` on `one`;
4. checks `one` can fetch the pinned image from ghcr, anonymously;
5. pulls the image if `one` lacks it and starts both services;
6. fetches `https://bookit.gsrpi.uk` from the control node, as a browser and as a Kobo,
   checks the app container runs the pinned image, and checks it publishes no port.

Nothing is built on `one`. The image is the fork's, built by its CI
(`.github/workflows/docker.yml` there) for arm64 and amd64, smoke-tested on native
runners, and tagged with the fork commit it was built from. An unchanged digest is already
on `one`, so the running container is left alone; a new one is pulled and the container
recreated. The package is public, so `one` holds no credential for it.

**The first run is the cutover.** Until then the container on `one` still publishes port
3001 and `one`'s host tunnel serves `bookit`. Sending a book fails from step 2 until step
5 ends: the image pull and a few seconds.

If that first run stops after step 2 and you want `bookit` back before fixing it, point
the record at `one`'s host tunnel again: in the Cloudflare dashboard, DNS, set the
`bookit` CNAME's target to `1e7fde2e-ac2f-4a5e-8ad4-591208c1e2a6.cfargotunnel.com` (the
`tunnel:` in `hosts/one/system/cloudflared-config.yml`). That works while the installed
host configuration still has its `bookit` rule and the old container still publishes 3001,
which is true until the run reaches step 5 and until you do the install below.

**Once, after that first run: install `one`'s host tunnel configuration without
`bookit`.**

```fish
ansible-playbook playbooks/server-install-system-files.yml -l one -e only=cloudflared-config.yml --check --diff -K
ansible-playbook playbooks/server-install-system-files.yml -l one -e only=cloudflared-config.yml -K
```

The diff removes the `bookit` rule and nothing else. You do not need to restart `one`'s
host connector: no DNS record sends `bookit` to it any more, so it makes no difference
when the connector reads the new file (at its next restart at the latest). Installed
before the first deploy, the file would take `bookit` down as soon as the connector read
it.

## After a reboot

Docker restarts both containers on its own (`restart: unless-stopped`). If they are
absent, run the play again, or on `one`:

```fish
cd ~/infra/deployments/send2ereader
sudo docker compose up -d
```

Compose refuses to start the project while `.env` lacks `TUNNEL_ID`, and its message
names the play that writes it.

## A new version

Every push to the fork's `master` publishes `ghcr.io/gsfernandes81/send2ereader:<commit>`.
To deploy one, put its tag **and** digest in `compose.yaml`'s `image:` line, commit and
push, then run the play. The digest is the record of what runs, which is why there is no
`SOURCE` here (`docs/decisions.md`). Read the digest without docker:

```fish
python3 -c 'import json,sys,urllib.request as u; s=sys.argv[1]; t=json.load(u.urlopen("https://ghcr.io/token?scope=repository:gsfernandes81/send2ereader:pull"))["token"]; r=u.Request("https://ghcr.io/v2/gsfernandes81/send2ereader/manifests/"+s, method="HEAD", headers={"Authorization":"Bearer "+t,"Accept":"application/vnd.oci.image.index.v1+json"}); print(u.urlopen(r).headers["Docker-Content-Digest"])' <the full fork commit>
```

**Once, after the first deploy from the image:** `one` still has the fork's checkout under
the old `SRC_ROOT` (in `.env`, e.g. `~/src/send2ereader`), and the image built from it if
an earlier deploy built one.
Neither is used now. Measure the checkout, then remove both when you choose; the stale
`SRC_ROOT` line in `.env` can go too.

## What not to do

- **Do not put a `ports:` entry back.** The sidecar reaches the app on the project
  network; a published port is a second way in that nothing guards.
- **Do not add `bookit` back to `hosts/one/system/cloudflared-config.yml`.** The DNS
  record points at the sidecar's tunnel, so a rule in `one`'s host tunnel would never
  receive a request, and the next reader of that file would think it did.
