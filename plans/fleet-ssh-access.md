# Plan: an Access gate on the fleet's ssh hostnames

**Built 2026-10-25; the rollout is the owner's and has not started.** The reasoning is in
[`docs/decisions.md`](../docs/decisions.md) § *The fleet's ssh hostnames are gated by
per-client service tokens*; this file is the rollout, and it is deleted when the rollout
is done.

## Rollout

1. **Every client gets its token.** On the phone, then in WSL on the laptop:

   ```fish
   cd ~/infra; git pull --ff-only; cd ansible
   ansible-playbook playbooks/client-home-ssh-config.yml
   ```

   The phone first: the laptop's `-s24` aliases run the phone's copy of the fleet script.
   `ssh zero` still working afterwards proves nothing yet, because no host is gated.

2. **Gate `one`, from the phone.** A dry run, then the real one; it lists the clients it
   will admit and asks for a yes.

   ```fish
   ansible-playbook playbooks/server-create-fleet-ssh-access.yml -e host=one --check
   ansible-playbook playbooks/server-create-fleet-ssh-access.yml -e host=one
   ```

3. **Check the laptop:** `ssh -S none one true` in WSL, and `ssh one` from Windows. If
   either fails, undo with `-e host=one -e remove=true` and stop.
4. **Then `two`, then `zero`,** each with steps 2 and 3. `zero` last, because it is the
   critical box.

A client that skipped step 1 cannot reach a gated host through its tunnel until it runs
the client play. On the home network, `zero-local`, `one-local` and `two-local` do not
cross Cloudflare.

**Undo, from anywhere:** `-e host=<host> -e remove=true` from the phone, or delete
`fleet ssh <host>` in Zero Trust, Access, Applications.

## Done when

All three hostnames answer an unauthenticated request with 403, every client reaches all
three, infra#12 is closed with the result, and this file is deleted.
