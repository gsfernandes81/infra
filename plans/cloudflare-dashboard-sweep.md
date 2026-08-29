# Plan — the Cloudflare dashboard sweep

**Deferred, deliberately.** 2g's playbook work is finished on all three hosts; this is its
manual tail, and it is the half no check on a box can do for you. Parked here rather than
left as a bullet in a phase row, because it needs a decision that only the owner can make
and getting it wrong locks a client out.

## Why it cannot be automated

The account holds **orphaned Access service tokens** from the failed runs of 2026-08-22,
and at least one is expected: it was created, its secret censored by `no_log` before it
was printed, and it is therefore unrecoverable. There are also **duplicate Access
applications** from the same runs.

Deleting the wrong service token revokes a live client. Cloudflare will not show you which
token a client is using, so the identification has to come from the client side:

```fish
cat ~/.config/infra-dev/token     # on the phone
cat ~/.config/or3-dev/token
```

The `TUNNEL_SERVICE_TOKEN_ID` in each of those **is** the `client_id` to keep. Everything
else named after those containers is a candidate for deletion. That is the judgement call,
and it is why this is not a playbook.

## What to sweep

[`../docs/cloudflare.md`](../docs/cloudflare.md) § *Safe to delete* is the list:

- **API tokens after use** — the migration needed `Account -> Cloudflare Tunnel -> Edit`,
  `Zone -> Zone -> Read` and `Zone -> DNS -> Edit` on `gsrpi.uk`, and nothing else. The
  one minted for `two`'s cutover on 2026-08-29 has done its job.
- **Orphaned Access service tokens**, identified as above.
- **Duplicate Access applications** from the same failed runs.

## Two things to check while in there

Both are recorded as unverified and nothing tracked settles them:

- **Did `ssh-zero-dev-or3.gsrpi.uk`'s CNAME actually get deleted** after `7bb2075` removed
  its ingress rule on 2026-08-24? A record left pointing at zero's tunnel now gets the
  catch-all 404, which reads like a container being down.
- **Was zero's connector cycled** at the time, so the removal actually took effect?

2i deletes `ssh-zero-dev-dd` and `ssh-zero-dev-ds` the same way, so all three can be
confirmed in one visit.

## Before deleting a service token

`docs/decisions.md` records that Cloudflare **refuses to delete a service token an Access
policy references** — `400`, code `12139`, `service_token_in_use`. So a token that will not
delete is telling you something true: some application still admits it. Find the policy
first rather than forcing it.

## Done when

Nothing in the account is named after a container that does not exist, every remaining
service token is one a client currently holds, and the three `ssh-zero-dev-*` records are
gone. Then delete this file — a finished plan is deleted, not archived.
