# Cloudflare simulation

`.github/workflows/cloudflare-sim.yml` runs two plays end to end with no Cloudflare
account. `mock_api.py` stands in for the parts of Cloudflare's API that `_cf-api-token.yml`
and `_cf-tunnel.yml` call, and for the Access applications, reusable policies and service
tokens that `server-create-fleet-ssh-access.yml` reads and writes, answering in Cloudflare's
envelope. `run-host-tunnel.sh` drives `server-create-host-tunnel.yml` against it with the
runner as the host; `run-fleet-ssh-access.sh` drives the Access play, described at the end.

## The host tunnel

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

### What a green run does not show

Cloudflare's real API: the stand-in answers only the fields the shared tasks read. Not the
edge either, since no connector runs, nor Access, which this play does not make, nor a
real host over ssh, since the runner is the host through a local connection.

### Running it elsewhere

`run-host-tunnel.sh` writes `/etc/cloudflared/three.json` as root and
`~/.config/cloudflare/api-token`, and refuses to start if either exists. Run it only on a
throwaway machine, never on the control node.

## The fleet's ssh gate

`run-fleet-ssh-access.sh` runs `server-create-fleet-ssh-access.yml` for `three`, which has
no `system/` and keeps its tunnel config under `leap/system/`. Until that config is
committed after the visit, the script writes a stand-in in its shape and removes it on
exit; once it is committed, the script uses it. It runs:

- no `-e host`, a host in `[fleet]` with no tracked config, and a Leap-only host whose ssh
  rule points at the wrong port: each must be refused by its own check, the last naming
  its `leap/system/` file;
- dry runs for `one`, which has both directories, and must read `system/`, and for
  `three`, which must read `leap/system/`; neither may write to Access;
- the real run: one application, `fleet ssh three`, on `ssh-three` only and not on
  `syncthing-three`, linked to one `non_identity` policy that admits the enabled fleet
  tokens and not the disabled one or a dev token, then the final message;
- a re-run, which must add nothing, and `-e remove=true`, which must delete the application
  and keep the policy;
- a gate that never takes, where the play's rescue must delete the application it made and
  say the hostname is open as before.

Every run's output is searched for the API token.

### What a green run does not show

The edge: the probe URLs point at the stand-in, which answers 403 for a hostname an
application covers and 200 otherwise, and 403 for the control. Not ssh through the gate,
since the ssh probe is `true`. Not the prompt either: without a TTY Ansible does not wait
at it, and the yes is an extra var, which beats the answer the prompt registers.

### Running it elsewhere

It needs no root. It sets `HOME` to a temporary directory for the run, with the API token,
a fleet token and an ssh config in it, and puts a shim first on `PATH` that hands `ssh`
that config with `-F`, since ssh reads its config from the passwd entry's home and not
`$HOME`. In the repo it writes `ansible/inventory.fleet-sim` and `hosts/simleap/`, and
`three`'s stand-in config when there is none, and removes them on exit.
