# Handoff, 2026-11-20: the dev hub moves from `zero` to `one`

The design and the record of what was decided are `plans/dev-hub-to-one.md`. This note
holds the blocks the owner runs after the infra agent goes down, and the next session's
orders.

## Where the move stands when this note is pushed

Done, with the output read by the agent:

- **Block 1:** `one` has `make`, the group `devstack` (gid 1001, `gavin` its only member),
  `main` at `464673e`, and the staging subvolume `/mnt/dev-move` on its SSD.
- **Block 2:** the five secrets directories and `dev/.env` are on `one`, at 0750/0640,
  group 1001. A uid-1001 container read every directory under SELinux. All nine images
  are built. `COMPOSE_PROFILES` is empty in `one`'s `.env`, so no tunnel can start there
  yet.
- **Block 3:** every container except `infra`, the hub and its tunnel is stopped on
  `zero`. Their 51 volumes are restored on `one`, each entry count matching `zero`'s.
  `destiny-director_dd-local-share` is 33 entries short: the 33 zed server sockets tar
  cannot copy.

Not moved, on purpose: `destiny-director_dd-mysql-data` on `zero`, which no compose file
names. Its repo's owner decides.

**Don't message the stopped sessions until block 7 passes.** The hub can wake a stopped
container when a message arrives, and on `zero` that container would run on volumes
already copied.

## Blocks 4 to 7, for the owner

Run them in order. Each says what to expect. The way back is at the end.

### Block 4: the agent goes down

Wait until the agent says it has pushed this note and opened the switch PR. Then:

```fish
# block 4, zero: stop the rest of the dev project on zero, infra first, then the hub, then its tunnel
sudo docker stop infra dev-hub dev-cloudflared
sudo docker ps --filter label=com.docker.compose.project=dev --format '{{.Names}}'
```

Expect the three names from `stop`, then nothing from `ps`. `ssh dev` stops answering
here; that is expected until block 6.

### Block 5: the last volumes

From the laptop's WSL, `ssh -A -o ControlPath=none zero` (the shared connection does not
forward the agent), then:

```fish
# block 5a, zero (the ssh -A session): stream the hub's and infra's volumes to one's staging
sudo -v
set vols dev_claude-sessions dev_hub-state dev_github-tokens dev_queue dev_claude-login dev_infra-workspace dev_infra-env infra-dev_infra-claude infra-dev_infra-gh infra-dev_infra-ssh-host infra-dev_infra-local-share
for v in $vols
    if not sudo test -d /var/lib/docker/volumes/$v/_data
        echo "MISSING on zero: $v"; continue
    end
    set n (sudo find /var/lib/docker/volumes/$v/_data | wc -l)
    sudo tar --numeric-owner -C /var/lib/docker/volumes/$v/_data -cf - . | ssh 192.168.86.101 "cat > /mnt/dev-move/$v.tar"
    set ps $pipestatus
    if test "$ps" = "0 0"
        echo "$v $n" | ssh 192.168.86.101 'cat >> /mnt/dev-move/manifest'; and echo "sent $v ($n entries)"
    else
        echo "FAIL $v (tar, ssh exit: $ps)"
    end
end
```

Expect eleven `sent` lines. `dev_hub-state` matters most: it holds the hub's ssh host
key, which every client pinned. A `FAIL` means stop; `zero` still holds every original.

Then on `one` (`ssh -o ControlPath=none one`):

```fish
# block 5b, one: restore each streamed volume under its compose name, check its entry count matches zero's, then delete its tar
sudo -v
for line in (cat /mnt/dev-move/manifest)
    set v (string split ' ' $line)[1]
    set n (string split ' ' $line)[2]
    set t /mnt/dev-move/$v.tar
    if not test -f $t
        echo "no tar for $v"; continue
    end
    if string match -q 'dev_*' $v
        sudo docker volume create --label com.docker.compose.project=dev --label com.docker.compose.volume=(string replace 'dev_' '' $v) $v >/dev/null
    else
        sudo docker volume create $v >/dev/null
    end
    sudo tar --numeric-owner -xpf $t -C (sudo docker volume inspect -f '{{.Mountpoint}}' $v)
    or begin; echo "FAIL extract $v (tar kept)"; continue; end
    set m (sudo docker run --rm -v $v:/v:ro docker.io/library/alpine:3.22 sh -c 'find /v | wc -l')
    if test "$m" = "$n"
        rm $t; echo "ok $v ($m entries)"
    else
        echo "COUNT MISMATCH $v: zero $n, one $m (tar kept)"
    end
end
mv /mnt/dev-move/manifest /mnt/dev-move/manifest.block5
```

Expect eleven `ok` lines. A `COUNT MISMATCH` whose difference is the number of `socket
ignored` lines block 5a printed for that volume is harmless; any other mismatch, stop and
use the way back.

### Block 6: bring-up on `one`

```fish
# block 6, one: every volume the stack names exists, then the tunnel on, then bring it up
set missing 0
for v in dev_claude-sessions dev_hub-state dev_github-tokens dev_queue dev_claude-login dev_infra-workspace dev_infra-env infra-dev_infra-claude infra-dev_infra-gh infra-dev_infra-ssh-host infra-dev_infra-local-share dev_or3-workspace dev_or3-env dev_dd-workspace dev_dd-env dev_ds-workspace dev_ds-env dev_invective-workspace dev_invective-env dev_nibbles-workspace dev_nibbles-env dev_ionic-workspace dev_ionic-env dev_claude-sessions-workspace dev_claude-sessions-env or3-dev_or3-claude or3-dev_or3-gh or3-dev_or3-ssh-host or3-dev_or3-local-share destiny-director_dd-uv-cache destiny-director_dd-claude destiny-director_dd-railway destiny-director_dd-gh destiny-director_dd-ssh-host destiny-director_dd-zed-server destiny-director_dd-local-share destiny-director_dd-postgres-data dossier_ds-uv-cache dossier_ds-claude dossier_ds-gh dossier_ds-ssh-host dossier_ds-zed-server dossier_ds-local-share invective-dev_invective-uv-cache invective-dev_invective-claude invective-dev_invective-gh invective-dev_invective-ssh-host invective-dev_invective-local-share nibbles-dev_nibbles-uv-cache nibbles-dev_nibbles-claude nibbles-dev_nibbles-gh nibbles-dev_nibbles-ssh-host nibbles-dev_nibbles-local-share ionic-dev_ionic-uv-cache ionic-dev_ionic-claude ionic-dev_ionic-gh ionic-dev_ionic-ssh-host ionic-dev_ionic-local-share claude-sessions_claude-sessions-claude claude-sessions_claude-sessions-gh claude-sessions_claude-sessions-ssh-host claude-sessions_claude-sessions-local-share
    sudo docker volume inspect $v >/dev/null 2>&1; or begin; echo "MISSING $v"; set missing 1; end
end
test $missing = 0; and echo "all 62 volumes present"
```

Expect `all 62 volumes present`. If any is `MISSING`, stop: `up` would create it empty.
Then:

```fish
# block 6, one: switch the tunnel on and start the whole stack
sed -i 's/^COMPOSE_PROFILES=.*/COMPOSE_PROFILES=tunnel/' ~/infra/dev/.env; and grep -n '^COMPOSE_PROFILES=' ~/infra/dev/.env
cd ~/infra/dev; and make up
```

Expect `COMPOSE_PROFILES=tunnel`, then the build steps as `CACHED`, then each container
`Started`. A `WARNING` from `make check` about a secrets directory means its group or mode
is wrong; paste it.

### Block 7: checks

```fish
# block 7, one: the stack's state and the tunnel's connections
sudo docker ps --filter label=com.docker.compose.project=dev --format '{{.Names}}\t{{.Status}}'
make -C ~/infra/dev tunnel-log | tail -20
```

Expect `dev-hub` and `dev-cloudflared` `(healthy)` within a minute or two, the others
`Up`, and `Registered tunnel connection` lines in the tunnel log.

Then from the laptop or the phone, `ssh dev`. Expect **no host key warning** and the
menu listing every container. A host key warning means `dev_hub-state` did not come
across: answer no, and use the way back.

Open a session in `infra` and tell it: *read docs/handoff/2026-11-20-dev-hub-to-one.md
and follow its orders for the next session.*

Once the session reports its own checks pass:

```fish
# block 7, one: remove the empty staging subvolume and unmount the SSD's top level
ls /mnt/dev-move; and sudo btrfs subvolume delete /mnt/dev-move; and sudo umount /mnt
```

### The way back

At any point until `zero`'s copy is removed. On `one`, the tunnel first:

```fish
# way back, one: stop the tunnel, then the rest of the stack
sudo docker stop dev-cloudflared
cd ~/infra/dev; and sudo docker compose stop
```

Then on `zero`. `start`, never `up`, which could recreate:

```fish
# way back, zero: start the stopped dev project as it was
cd ~/infra/dev; and sudo docker compose start
```

Work done on `one` in between stays on `one` unless it was pushed.

## Orders for the next session

The next session is the infra agent, starting in its container on `one`.

1. **Check where you are, and report before doing anything else.** `/proc/meminfo` shows
   about 8 GB on `one`, not 4. Your memories load, `/workspace` is on `main` and its
   worktrees are there. `ssh dev` answered without a warning (the owner says so).
2. **The switch PR** (branch `dev-hub-switch`) moves `hosts/zero/dev` to `hosts/one/dev`,
   the plays' defaults, and the docs. Read it against the repo, check its CI, and merge
   it **on the owner's go**. Until it merges, `main` still says the stack is on `zero`.
3. **Never `make up` or `start` the dev project on `zero`** except as the way back. Its
   `.env` still names the tunnel, so it would start a second connector, and `ssh dev`
   would land on either hub at random.
4. **About 2026-11-23, remove `zero`'s copy**, at the owner's say: measure first, then
   `make down` on `zero`, its dev volumes by name (the lists in block 3a and 5a), the
   five secrets directories (the tunnel credentials must not stay on a box that could
   start a second connector) and the dev images. "Exited" is not "absent" (CLAUDE.md).
   Ask about `destiny-director_dd-mysql-data`.
5. **Then delete this note and `plans/dev-hub-to-one.md`**, after checking the switch PR's
   decisions row holds everything durable. Remove the worktrees `dev-hub-to-one`,
   `dev-hub-switch` and `dev-hub-handoff` once their branches are merged.
6. **Next piece:** `zero` to Leap 16.1 Immutable. The owner's description: they are at the
   box with the new SD card and a Combustion stick, boot it, finish over ssh, and the
   Alpine card is the way back. It gets its own design, as `one`'s and `three`'s did; it
   is started on the branch `zero-leap`, in `plans/zero-leap.md`.
