# Alpine simulation

`.github/workflows/alpine-sim.yml` runs the setup plays against an Alpine container that
stands in for `zero`: `server-install-tailscale.yml`, `server-create-backup-key.yml` and
`server-store-backup-ntfy-url.yml`. `host/Dockerfile` is the box: Alpine 3.24, as on the
fleet, with OpenRC as init, sshd, and gavin with sudo. `run-setup-plays.sh` builds it,
reaches it over ssh as Ansible reaches a fleet host, and names each check PASS or FAIL;
any FAIL fails the job. The job runs on an arm64 runner, so the real tarball's binaries
run in the container as they would on `zero`.

The container's hostname is `zero`, its checkout is cloned from this commit, and the plays
pull it and require it to match, as on the fleet. The inventory also names it `two`, which
tracks no `tailscaled` and no backup, and names the runner `one`, which is not Alpine.

## What it runs

The Tailscale play:

- the refusals: no `-e target`, a host that is not Alpine, a host with no tracked
  `tailscaled`, and Alpine's own `tailscale` installed. Each must stop the play by its own
  check, confirmed from that check's message, with nothing installed;
- a dry run on a bare box, which must install and enable nothing;
- the real pin: the tarball downloaded and checked against `group_vars/fleet.yml`, both
  binaries installed and reporting the pin, the service byte-identical to the tracked file,
  in the default runlevel and started, and the real `tailscale up` reading a made-up key
  from its file and Tailscale refusing it, with the file gone afterwards. The real
  `tailscale debug prefs` must carry the two settings the play checks after a join;
- a stand-in tarball at 9.9.1, served by `serve.py`: the real binaries kept as `.previous`,
  `tailscaled` restarted, and the join run once, with `--advertise-tags=tag:fleet`,
  `--accept-dns=false` and the key from a root 0600 file in `/run`, never in argv;
- a re-run, which must not restart or join; the pin moved to 9.9.2, which must restart
  and not join; a pin whose SHA-256 is wrong, which must change nothing;
- a box off the tailnet with no key, which must stop at the key check; with a key, which
  must join; and a join that rewrites `/etc/resolv.conf`, which must fail the play.

The backup key play: refused off the tailnet and on a host with no backup push; a dry run
that makes nothing; a real run that makes an ed25519 key, root 0600 in a 0700 directory,
commented `zero mirror-backup`, and prints it with its fingerprint and the address; and a
re-run that leaves the key as it was.

The ntfy play: refused a value that is not a URL; a dry run that writes and sends nothing;
a real run that stores the URL root 0600 in a 0700 directory and sends one test message,
printing its status; a re-run that changes and sends nothing; and a topic answering 403,
which must fail the play with the URL stored.

Every run's output is searched for the auth keys, the topic and the private backup key.
The joining run and the first ntfy run also go through the default callback at `-vv`,
because the repo's own callback prints no successful result and would hide a missing
`no_log`.

## What a green run does not show

A real join: no auth key exists in CI, so the real `tailscale up` is shown only refusing a
made-up key, and the stand-in's `up` stands for the rest. A Pi's kernel, and OpenRC as it
boots on bare metal rather than in a container. ntfy itself: `serve.py` answers the test
message. And a connection over the tailnet, which the Tailscale play refuses to restart
through and which the runner has no way to make.

## Running it elsewhere

It builds and runs a privileged container, binds `127.0.0.1:2222`, and writes
`ansible/inventory.sim` and `~/.ssh/cp`, so it belongs on a throwaway machine with Docker,
never on the control node.
