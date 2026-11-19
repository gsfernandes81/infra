# Cloudflare simulation

`.github/workflows/cloudflare-sim.yml` runs three plays end to end with no Cloudflare
account, and the Access tasks a fourth shares. `mock_api.py` stands in for the parts of Cloudflare's API that `_cf-api-token.yml`
and `_cf-tunnel.yml` call, for the Access applications, reusable policies and service
tokens that `server-create-fleet-ssh-access.yml` reads and writes, and for the applications,
app-scoped policies and records that `server-create-browser-login.yml` writes, answering in
Cloudflare's envelope. An application or app-scoped policy comes back as Cloudflare sends
one, with ids, timestamps and defaults nobody sent, `session_duration` in Go's long form
(`24h0m0s`) and include rules reversed, so `_cf-access-app.yml`'s compare is tested against
more than its own echo. Each write to one is counted in `access_writes`. `run-host-tunnel.sh` drives `server-create-host-tunnel.yml` against
it with the runner as the host, a made-up `simnew`; `run-fleet-ssh-access.sh` and `run-browser-login.sh` drive
the two Access plays, and `run-access-pair.sh` the deployment play's two Access
applications, all described after it.

## The host tunnel

The new host is `simnew`, which is in the script's own inventory and has nothing under
`hosts/`, so it stays new whatever the fleet's hosts commit. It was `three` until `three`'s
tunnel config was committed on 2026-11-18. The script names each check PASS or FAIL and
fails the job on any FAIL. Each adverse case must stop the play by its own check, which the
script confirms from that check's message, not from the exit code alone. It runs:

- no `-e target`, an unknown host, a group name, `zero`, whose tracked tunnel config is
  under `system/`, and `three`, whose config is under `leap/system/`: each must be refused
  with nothing created;
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

`run-host-tunnel.sh` writes `/etc/cloudflared/simnew.json` as root and
`~/.config/cloudflare/api-token`, and refuses to start if either exists. Run it only on a
throwaway machine, never on the control node.

## The fleet's ssh gate

`run-fleet-ssh-access.sh` runs `server-create-fleet-ssh-access.yml` for `three`, whose
`leap/MOVED` says it runs Leap, so its tunnel config is read from `leap/system/`. Until
that config is committed after the visit, the script writes a stand-in in its shape and
removes it on exit; once it is committed, the script uses it. It runs:

- no `-e host`, a host in `[fleet]` with no tracked config, and a stand-in host with both
  directories whose ssh rule points at the wrong port in each: each must be refused by its
  own check, the stand-in first naming its `system/` file and then, once the script writes
  its `leap/MOVED`, its `leap/system/` file;
- dry runs for `one`, which keeps its Alpine `system/` beside `leap/system/` and a
  `leap/MOVED`, and must read `leap/system/`, and for `three`, which must read
  `leap/system/` too; neither may write to Access;
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

## The browser login

`run-browser-login.sh` runs `server-create-browser-login.yml` for `syncthing-three` on
`three`, with the same stand-in for `three`'s tunnel config as the ssh gate's script, and
the tunnel and `ssh-three`'s record planted in the stand-in as the host tunnel play leaves
them. It runs:

- no `-e host`, a host with no tracked config, and a Leap host (by its `leap/MOVED`) whose
  config names no tunnel; no `-e subdomain`, `ssh-three`, and a name not in the ingress; no
  address list, and one with a line that is not an address: each must be refused by its own
  check, with nothing made;
- a tunnel the account does not have, one that `ssh-three` does not point at, an
  application on the hostname that the play did not make, and a probe whose known login
  does not read as one: each refused, with no record made;
- a dry run, which must say what it would do and write nothing;
- the real run: one application, `syncthing-three`, 24 hours, with one `allow` policy
  admitting exactly the addresses in the file; one proxied CNAME to `three`'s tunnel; and,
  from the stand-in's record of each DNS write, the login already covering the hostname
  when its record was written, the policy's request before the record's;
- a re-run, which must add no application or policy, make no PUT or POST to either, print
  no Access write and still read the policies back, and leave the record untouched; and one
  after the record was pointed elsewhere, which must point it back;
- a field the play sets, changed in the stand-in as if by hand: the session duration, a
  login method pinned, the launcher turned on, an address removed, and the policy renamed
  with a `require` rule. Each run after one must write only the object it touches, say which
  field differed (never an address), and repair it; the run after that must write nothing;
- an application write the stand-in ignores, which the read-back must stop on, naming the
  field, before the policy; and a field the stand-in leaves out of its answers, which must
  be written, said to be unprovable, and not fail the run;
- a refused Access write, which must stop with Cloudflare's reason and write no record;
- the proof failing after the record exists: with the hostname answering from behind
  Access, the probe must stop at that first answer and the rescue must delete the record and
  keep the application, reading a 404 on the delete as gone, and printing Cloudflare's
  reason and saying the hostname may be open when the delete is refused; with no answer at
  all, it must retry to the end, keep the record and say to re-run, and the re-run must
  finish.

Every run's output is searched for the API token and for the allowed addresses.

### What a green run does not show

The edge: the probe URLs point at the stand-in, which answers a 302 to a
`cloudflareaccess.com` login for a hostname covered by an application with an `allow`
policy, and 200 otherwise. Not a login either, nor Syncthing behind it, nor whether
Cloudflare keeps app-scoped policies on an application PUT whole: the stand-in keeps them,
and the play reads them back on the real API rather than assume it. Nor the forms
Cloudflare really answers in: the stand-in's extra fields, long durations and reversed
rules are what the compare must survive, not a record of Cloudflare's replies.

### Running it elsewhere

It needs no root. Like the ssh gate's script it sets `HOME` to a temporary directory, with
the API token and the address list in it, and writes `ansible/inventory.login-sim` and
`hosts/simleap/`, and `three`'s stand-in config when there is none, removing them on exit.

## The deployment play's two applications

`run-access-pair.sh` runs `access-pair.yml`, a driver that imports `_cf-access-app.yml`
twice as `server-create-deployment-tunnel.yml` does: a login on `pairsim.gsrpi.uk` with an
`allow` policy, then a no-login application on `pairsim.gsrpi.uk/kobo` with a `bypass`
policy admitting everyone. That play needs a host, its checkout and a tunnel, so only the
part it shares is driven. It runs:

- a dry run, which must write nothing;
- the first run: both applications, each with its one policy, created in that order, and
  each import reading its own policies back;
- a re-run, which must make no PUT or POST to either and whose recap counts no change;
- both durations and both policies' rules changed, which each import must repair on its
  own application; then an address removed, which only the login's policy write may
  repair, and a run after it that writes nothing.

Every run's output is searched for the API token and the allowed addresses. It needs no
root and writes nothing outside a temporary directory.
