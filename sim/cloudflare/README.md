# Cloudflare simulation

`.github/workflows/cloudflare-sim.yml` runs
`ansible/playbooks/server-create-host-tunnel.yml` end to end with no Cloudflare account.
`mock_api.py` stands in for the parts of Cloudflare's API that `_cf-api-token.yml` and
`_cf-tunnel.yml` call, answering in Cloudflare's envelope, and `run-host-tunnel.sh` drives
the play against it with the runner as the host.

The script names each check PASS or FAIL and fails the job on any FAIL. It runs:

- no `-e target`, and a rejected token: both must stop the play with nothing created;
- a dry run: it must exit 0 with no tunnel, no record and no credentials;
- the real run: one tunnel named for the host, a proxied CNAME `ssh-<host>.<dns_zone>` to
  it, and credentials at `/etc/cloudflared/<host>.json`, root 0600, naming the tunnel,
  account and secret the stand-in received;
- a re-run, which must change nothing, and one after the CNAME is pointed elsewhere, which
  must repair it in place;
- a tunnel deleted at Cloudflare, which must stop the play without a replacement;
- a refused write, which must stop the play, print Cloudflare's reason and write no
  credentials.

Every run's output is also searched for the API token, which must never appear.

## What a green run does not show

Cloudflare's real API: the stand-in answers only the fields the shared tasks read. Not the
edge either, since no connector runs, nor Access, which this play does not make, nor a
real host over ssh, since the runner is the host through a local connection.

## Running it elsewhere

`run-host-tunnel.sh` writes `/etc/cloudflared/three.json` as root and
`~/.config/cloudflare/api-token`, and refuses to start if either exists. Run it only on a
throwaway machine, never on the control node.
