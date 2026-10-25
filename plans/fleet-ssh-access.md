# Plan: an Access gate on the fleet's ssh hostnames

**Proposed 2026-10-25, not built.** `ssh-zero`, `ssh-one` and `ssh-two` are not behind
Access: with no credentials, a WebSocket upgrade reaches sshd's banner on all three
([infra#12](https://github.com/gsfernandes81/infra/issues/12), `docs/cloudflare.md`
§ *Open*). The owner chose per-client service tokens, the mechanism the dev containers
use, over a browser login whose expiry broke `ssh zero` from the phone in August.
Reviewed by a Fable advisor the same day; the changes it asked for are in.

## The hazard

The gate stands in front of the only way into all three Pis from outside the house. A
client that the gate does not admit gets `websocket: bad handshake` on all three. So the
gate goes up one host at a time, each one created already admitting the clients, each one
proved with a probe that cannot pass for the wrong reason, and each one undone by deleting
one object.

## What gets built

**Each client mints its own `fleet-<client>` service token and presents it.** The fleet
half of `client-home-ssh-config.yml` does for `fleet` what `_client-dev-ssh.yml` does for
each dev container: mint (or rotate) the token, write `~/.config/fleet/token` at 0600, and
change the `zero`, `one` and `two` ProxyCommand to the dev containers' form, which sources
the token into one short-lived `cloudflared`. Windows gets the same batch wrapper. The
`*-s24` hop runs `cloudflared` on the phone, so the phone's client run writes a small
script there, `~/.config/fleet/access-ssh`, that sources the phone's token and runs
`cloudflared access ssh --hostname "$1"`; the s24 ProxyCommand names that script, with no
nested quoting.

**The token never expires on its own.** Cloudflare's default lifetime is one year, and the
dev containers' tokens were minted with that default. A fleet token minted that way would
shut every client out of every Pi a year later, with the same error as the August expiry.
So the fleet token is minted with `duration: forever`. A lost laptop is still one token to
delete.

Minting needs no gate: a service token is an account object, and presenting one to an
ungated hostname changes nothing. When the gate for a host exists, the client run also
adds its token to that host's policy, so a new laptop joins by running the client play.

**One Access application per host: `fleet ssh zero`, `fleet ssh one`, `fleet ssh two`.**
Each is created in one call with its policy inline (decision `non_identity`, including
every `fleet-*` token), so it never exists admitting nobody. Undoing one host is deleting
its application, which leaves the other two as they were.

## The server play, one host per run

`server-create-fleet-ssh-access.yml -e host=one` runs from the control node. It touches no
host, so it needs no `-K`.

1. **Calibrates.** A plain GET to `infra-dev.gsrpi.uk` must read 403 (known gated) and to
   the target must read 200 (known open). Otherwise the probes below cannot be trusted,
   and it stops.
2. **Refuses** if any application already covers the hostname, by `domain` or any
   `destinations` entry, that this play did not make. The August applications may still
   exist set to bypass; removing Access in front of something is the owner's call.
3. **Prints the tokens it will admit** and stops for a yes. Missing one is how a client
   gets locked out, and only the owner knows every client.
4. **Creates the application** with its policy inline, then reads the policy back.
5. **Waits for the gate.** It polls the target until a plain GET answers 403, or 302 to
   `cloudflareaccess.com`. Never just "not 200", which a DNS failure also is. Access
   changes take time to reach the edge, so this must succeed before step 6 can mean
   anything. On timeout it deletes the application.
6. **Proves this client gets through:** `ssh -S none -o BatchMode=yes -o ConnectTimeout=20
   <host> true`. `-S none` bypasses the open-connection reuse (`ControlMaster`) in the ssh
   config, which would otherwise pass without crossing Cloudflare at all. On failure it
   deletes the application.

The play can prove only the token of the machine it runs on. So after each host, the
laptop checks itself before the next host is gated: `ssh -S none one true` in WSL, and
`ssh one` from Windows.

## Rollout

1. On each client (phone, WSL on the laptop): `client-home-ssh-config.yml`. `ssh zero`
   still working proves nothing yet, because no gate exists; the real test is step 2.
2. From the phone: `server-create-fleet-ssh-access.yml -e host=one`, then the laptop's
   check. Then `two`, then `zero` last, because it is the critical box.
3. A client that skipped step 1 is shut out of the gated hostnames until it runs the
   client play. `zero-local`, `one-local` and `two-local`, on the home network, do not
   cross Cloudflare.

**Undo, from anywhere with a browser:** delete that host's `fleet ssh` application in the
Zero Trust dashboard, and the hostname is open again. An ssh session already open when a
gate goes up probably survives it (expected, not verified); nothing in the rollout relies
on it.

## Not in this plan

- `KbdInteractiveAuthentication no` in `sshd-infra.conf`: a change to sshd itself, needing
  the two-phase procedure, not chosen yet.
- The dev containers' tokens expiring a year after minting: filed separately in
  `docs/management-plane.md`; a refresh extends them without re-minting.
- The fleet ssh block's comment, which says the boxes' tunnels admit you on your
  certificate, is corrected in the same commit as the client change.

## Done when

All three hostnames answer an unauthenticated request with 403, every client reaches all
three, `docs/cloudflare.md` and `docs/ssh-clients.md` describe it, infra#12 is closed, and
this file's reasoning is in `docs/decisions.md` and the file deleted.
