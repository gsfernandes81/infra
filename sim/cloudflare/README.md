# Cloudflare simulation

`.github/workflows/cloudflare-sim.yml` runs
`ansible/playbooks/server-create-host-tunnel.yml` end to end with no Cloudflare account.
`mock_api.py` stands in for the parts of Cloudflare's API that `_cf-api-token.yml` and
`_cf-tunnel.yml` call, answering in Cloudflare's envelope, and `run-host-tunnel.sh` drives
the play against it with the runner as the host.

The script names each check PASS or FAIL and fails the job on any FAIL. Each adverse case
must stop the play by its own check, which the script confirms from that check's message,
not from the exit code alone. It runs:

- no `-e target`, an unknown host, a group name, and `zero`, which has a tracked tunnel
  config: each must be refused with nothing created;
- a rejected token, which must stop the play with no credentials written;
- a dry run: it must exit 0 with no tunnel, no record and no credentials;
- the real run: one tunnel named for the host, a proxied CNAME `ssh-<host>.<dns_zone>` to
  it, and credentials at `/etc/cloudflared/<host>.json`, root 0600, naming the tunnel,
  account and secret the stand-in received;
- a re-run, which must change nothing, and re-runs after the CNAME is pointed elsewhere or
  unproxied, which must repair it in place;
- a tunnel deleted at Cloudflare, which must stop the play without a replacement;
- a refused write, which must stop the play, print Cloudflare's reason and write no
  credentials;
- a partial failure, with the tunnel made and the DNS refused, whose re-run must finish
  the job; then the credentials lost while the tunnel lives on, which must stop on the
  name in use; then a stale A record at the hostname, which must stop with Cloudflare's
  reason.

Every run's output is searched for the API token, every tunnel secret the stand-in has
seen, and the credentials file in base64. The real run and one re-run also go through the
default callback at `-vv`, the transcript `ansible.cfg` names for diagnosing, because the
repo's own callback prints no successful result and would hide a missing `no_log`.

## What a green run does not show

Cloudflare's real API: the stand-in answers only the fields the shared tasks read. Not the
edge either, since no connector runs, nor Access, which this play does not make, nor a
real host over ssh, since the runner is the host through a local connection.

## Running it elsewhere

`run-host-tunnel.sh` writes `/etc/cloudflared/three.json` as root and
`~/.config/cloudflare/api-token`, and refuses to start if either exists. Run it only on a
throwaway machine, never on the control node.
