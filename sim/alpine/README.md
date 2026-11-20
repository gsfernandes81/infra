# Alpine simulation

`.github/workflows/alpine-sim.yml` runs the setup plays against an Alpine container that
stands in for `zero`: `server-install-tailscale.yml`, `server-create-restore-key.yml` and
`server-store-backup-ntfy-url.yml`, and the dry run of `server-install-system-files.yml`;
then `zero`'s snapper install, and `install-system-file`'s sudoers check. `host/Dockerfile` is the box: Alpine 3.24, as on the
fleet, with OpenRC as init, sshd, and gavin with sudo. `run-setup-plays.sh` builds it,
reaches it over ssh as Ansible reaches a fleet host, and names each check PASS or FAIL;
any FAIL fails the job. The job runs on an arm64 runner, so the real tarball's binaries
run in the container as they would on `zero`.

The container's hostname is `zero`, its checkout is cloned from this commit, and the plays
pull it and require it to match, as on the fleet. The inventory also names it `two`, which
tracks no `tailscaled` and serves `three` no snapshots, and names the runner `one`, which
is not Alpine.

## What it runs

The Tailscale play:

- the refusals: no `-e target`, a host that is not Alpine, a host with no tracked
  `tailscaled`, and Alpine's own `tailscale` installed. Each must stop the play by its own
  check, confirmed from that check's message, with nothing installed;
- a dry run on a bare box, which must install and enable nothing;
- the real pin: the tarball downloaded and checked against `group_vars/fleet.yml`, both
  binaries installed and reporting the pin, the service byte-identical to the tracked
  file, in the default runlevel and started, and the real `tailscale up` reading a made-up key
  from its file and Tailscale refusing it, with the file gone afterwards. The real
  `tailscale debug prefs` must carry the two settings the play checks after a join;
- a stand-in tarball at 9.9.1, served by `serve.py`: the real binaries kept as
  `.previous`, `tailscaled` restarted, and the join run once, with `--advertise-tags=tag:fleet`,
  `--accept-dns=false` and the key from a root 0600 file in `/run`, never in argv;
- a re-run, which must not restart or join and must sweep a key file a killed run
  left; the pin moved to 9.9.2, which must restart and not join; 9.9.2 on disk with 9.9.1
  still running, which must restart; a restart wanted over a connection from
  `100.64.77.1`, a second Docker network in the tailnet's range, which must be refused
  with nothing touched; and a pin whose SHA-256 is wrong, which must stop at the first
  mismatch, without retrying, and change nothing;
- a box off the tailnet with no key, which must stop at the key check; with a key, which
  must join; and a join that rewrites `/etc/resolv.conf`, which must fail the play.

The restore key play: refused off the tailnet and on a host `three` does not pull from; a
dry run that makes nothing; a real run that makes an ed25519 key, root 0600 in a 0700
directory, commented `zero restore`, and prints it, the address, the box's ssh host key and
both fingerprints; and a re-run that leaves the key as it was.

The ntfy play: refused a value that is not a URL; a dry run that writes and sends nothing;
a real run that stores the URL root 0600 in a 0700 directory and sends one test message,
printing its status; a re-run that changes and sends nothing; and a topic answering 403,
which must fail the play with the URL stored.

The system files play, in `--check` only: `install-system-file --list` on the box must name
the files the play found for `zero` before it asked the tool, and the play must read the
same list, refuse `backup-age-check` by its `infra-init: none`, narrow it with `-e only`,
install nothing, and refuse `two`, whose name is not the box's hostname. Then the box answers as `three`: `--list` must read
`hosts/three/leap/system/`, since `three` has a `leap/MOVED`, and `-l three -e
only=cloudflared-config.yml` must list that one file and have the tool refuse it, because
it declares systemd and the box runs OpenRC.

`zero`'s snapper, as `hosts/zero/system/README.md` § The backup installs it, on Alpine 3.24
arm64, `zero`'s release and architecture: the URL and the `sha256sum` line are read out of
the README and run as they are, and must print `OK`; apk must refuse a copy with bytes
changed, which its signature no longer matches; apk must install the file with its
dependencies from Alpine 3.24's own repositories, pin `snapper=0.13.1-r0` in its world, and
leave it out of an `apk upgrade`; no runlevel may start `dbus`, which apk installs with it;
`snapper --no-dbus` must answer; the package's hourly script must read an empty
`SNAPPER_CONFIGS`; and `/bin/setpriv` must be util-linux's only once `setpriv` is added.

`install-system-file`'s sudoers check, calibrated first: `visudo -cf` must pass the box's own
`/etc/sudoers.d/gavin`, the dry run of `sudoers-backup` must pass its pre-check, and a copy
broken in the checkout must be refused before anything is written, with sudo still working.

The dev containers' play: refused a target outside the fleet and a host whose checkout has
no `dev/Makefile`; `--check` says what it would run and runs nothing; the real
`dev/Makefile`, run as root on the box, which has no Docker, must stop at its first guard,
the missing `dev/.env`, with its refusal printed and the play failed; and a stand-in
checkout's `make up` must print that it ran as uid 0 in `dev/`.

The unlock play, `server-unlock-arrays.yml`, typed at in a terminal by
`sim/microos/host/play-prompts.py`: on the box, whose init is OpenRC, it must refuse the
volume by naming its init and ask nothing; on the runner, `one`, which runs systemd, it
must refuse a volume crypttab does not name, unprivileged, and then, with a LUKS volume on a
loop device and its crypttab and fstab lines, report a wrong passphrase and leave the
volume locked with its unit neither active nor failed, unlock it with the right one at
`-vv` through the default callback, leaving `systemd-cryptsetup@simrun.service` active and
the volume mounted `nosuid`, and report it already open on a re-run without asking; and
the runner's journal must not hold the passphrase. The
unlock on Leap, three's own, is `microos-sim.yml`'s.

Every run's output is searched for the auth keys, the topic and the private restore key,
and the unlock play's for the passphrase.
The joining run and the first ntfy run also go through the default callback at `-vv`,
because the repo's own callback prints no successful result and would hide a missing
`no_log`.

## What a green run does not show

A real join: no auth key exists in CI, so the real `tailscale up` is shown only refusing a
made-up key, and the stand-in's `up` stands for the rest. A Pi's kernel, and OpenRC as it
boots on bare metal rather than in a container. ntfy itself: `serve.py` answers the test
message. And a real tailnet: the refusal to restart over it is shown only from an
address in its range.

## The encrypted member

A second job runs `run-dmcrypt.sh`: `zero`'s encrypted array member
([`plans/visit-runbook.md`](../../plans/visit-runbook.md) § Slice 2) as far as a container
takes it, in a box built from the same `host/Dockerfile`, against a LUKS2 volume on a loop
device that stands in for `zero`'s new bcache device. It runs:

- the key file made with the runbook's commands, and the format and passphrase slot with
  the runbook's flags: Adiantum, the label, two keyslots, Argon2 at 256 MiB, read back
  from `luksDump`. One flag is added, `--uuid`: the stand-in takes the LUKS UUID the
  tracked `hosts/zero/system/dmcrypt` names, so the file checked and installed below is
  the tracked one, unchanged. If the entry carries `FILL-FROM-LUKS-UUID` again, as it may
  between a disk swap and the commit that names the new UUID, a fresh UUID stands in for
  it; anything else in `source=`, or more than one entry, stops the run;
- `findfs UUID=` resolving the LUKS2 UUID, BusyBox's and then util-linux's, since
  `dmcrypt` resolves `source=` with whichever `zero` has;
- `install-system-file dmcrypt`: refusing the entry before the format, while no volume
  has its UUID, so the pass after it is the volume's doing; refusing the placeholder,
  written back in for the purpose; then passing the good entry and refusing an unknown
  UUID, an entry with no `key=`, a key file outside `/etc`, a name dmcrypt does not read,
  a key file others can read and a key that does not open the volume; then installing it
  over cryptsetup-openrc's own `/etc/conf.d/dmcrypt`, with `bcache-register` and
  `dm-crypt.conf`;
- OpenRC's recorded order for `dmcrypt`, read with the runbook's own `grep` of the
  deptree (after `bcache-register` and `modules`, before `btrfs-scan`; `localmount` and
  `fsck` carry `keyword -docker`, so a container's deptree leaves them out); then the boot runlevel started for real, which must start `bcache-register`,
  then `dmcrypt`, which opens `data-4` with the key file, then `btrfs-scan`, which
  registers it; and the btrfs inside reading back;
- `dmcrypt` with the key file missing, and with a wrong one: each must return without
  asking anyone, and map nothing; and its output must name the missing key file, or show
  it tried `data-4` and failed, so a conf with no entry cannot pass either check.

**What it does not show:** a Pi's kernel (the runner's arm64 kernel provides dm-crypt and
Adiantum here), bcache (`bcache-register` waits its 30 seconds for devices that never come
and exits 0), a two-device array, and OpenRC as it boots on bare metal. The reboot test on
`zero`, at step 10 of the slice, is the proof of those.

## Running it elsewhere

It builds and runs a privileged container, binds `127.0.0.1:2222`, and writes
`ansible/inventory.sim` and `~/.ssh/cp`, so it belongs on a throwaway machine with Docker,
never on the control node.
