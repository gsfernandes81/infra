# pearl-wallet

Pearl's Oyster wallet daemon on `zero`, holding the owner's mining-pool payouts. It is a
wallet only: no miner and no `pearld`. Oyster syncs over Pearl's light client, which asks
peers for block headers and filters instead of keeping the chain. Nothing is published:
the owner reaches it with `docker exec` on `zero`. The reasoning is
[`docs/decisions.md`](../../docs/decisions.md) § *Pearl wallet on `zero`*.

| | |
|---|---|
| `compose.yaml` | the one service; no `ports:`; read-only root, every capability dropped, 256 MB |
| `Dockerfile` | `oyster` and `prlctl` from upstream's arm64 release, checked against its sha256 |
| `oyster.conf` | light client on, RPC on the container's loopback; its password is not a secret, and its header says why |
| `prlctl.conf` | lets `prlctl` reach Oyster with no flags |

The preflight hook, `ansible/deploy-hooks/pearl-wallet/preflight.yml`, stops a deploy
while there is no wallet, and when the image tag and the Dockerfile name different
releases.

## The seed is the backup

Oyster shows a 12-word seed phrase once, when the wallet is created. Anyone with those
words has the coins, and without them a lost wallet cannot be rebuilt.

- Write the words on paper, with the date. The date is what a restore needs (below).
- Never type the words into a phone note, a chat, a password manager synced to a cloud,
  or this repo.
- Nothing backs up the wallet volume, by design. The seed rebuilds the wallet on any
  machine, so a copy of the file would only be a second place the keys live.
- The private passphrase you choose encrypts the keys in the wallet file. Sending needs
  it; receiving and checking the balance do not.

## Setting it up

Three steps, in order. Each block's first line says where it runs. On `zero`, run
`ssh zero` first and paste the block inside that shell.

### 1. Create the wallet, once

```fish
# 1. on zero: build the image and create the wallet
cd ~/infra; git pull --ff-only
cd deployments/pearl-wallet
sudo docker compose build
sudo docker compose run --rm -it pearl-wallet --create
```

Oyster asks four things:

| Prompt | Answer |
|---|---|
| private passphrase, then again to confirm | one you will remember; it is stored nowhere |
| *add an additional layer of encryption for public data?* | **no** (Enter). Yes would mean Oyster needs that passphrase at every start, so it would have to sit on `zero` |
| *Do you have an existing wallet seed?* | **no** (Enter) |
| the seed phrase is shown | write it and today's date on paper, check each word, then type `OK` |

The container exits and removes itself. The wallet stays in the `pearl-wallet_wallet`
volume.

### 2. Start it

```fish
# 2. on the phone: deploy pearl-wallet to zero
cd ~/infra/ansible; ansible-playbook playbooks/server-deploy-compose.yml -e deployment=pearl-wallet -K
```

The play shows its plan, asks once, starts the container and waits for its healthcheck.

### 3. Give the pool an address

```fish
# 3. on zero: a receiving address for the pool
sudo docker exec pearl-wallet prlctl getnewaddress
```

Set the printed address as the payout address at the pool. Every call makes a new
address, and all of them belong to this wallet.

## Day to day

```fish
# on zero: the balance and the latest payouts
sudo docker exec pearl-wallet prlctl getbalance
sudo docker exec pearl-wallet prlctl listtransactions
```

A balance of 0 just after a start can mean the light client has not caught up yet. The
log shows how far it is: `sudo docker logs --tail 20 pearl-wallet`.

## Sending

Sending needs the private passphrase. Start each line with a space, so fish leaves it out
of its history.

```fish
# on zero: unlock for 60 seconds, send, lock again
 sudo docker exec -i pearl-wallet prlctl walletpassphrase - 60
 sudo docker exec pearl-wallet prlctl sendtoaddress <address> <amount>
 sudo docker exec pearl-wallet prlctl walletlock
```

The `-` makes `prlctl` read the passphrase from the next line you type, so it never sits
on a command line. It shows on the screen as you type it.

## Restoring from the seed

Restore with `--createfromfile`, not `--create`. `--create` dates a restored wallet
today, and the light client only looks for coins from a wallet's date onwards, so the
balance would read 0.

`--createfromfile` reads a JSON file holding the passphrase, the seed and the date as
Unix seconds. Use the date on the paper, or any earlier date; an earlier date costs only
a longer scan. The file holds the seed, so it lives in RAM and is deleted at once.

```fish
# on the new host: restore the wallet from the seed
cd ~/infra/deployments/pearl-wallet
sudo docker compose build
date -d 2026-10-30 +%s                  # the date on the paper, as Unix seconds
sudo install -m 0400 -o 65532 /dev/null /dev/shm/pearl-restore.json
sudo vi /dev/shm/pearl-restore.json     # {"PrivatePassphrase": "…", "Seed": "word1 … word12", "Bday": "<seconds>"}
sudo docker compose run --rm -it -v /dev/shm/pearl-restore.json:/restore.json:ro pearl-wallet --createfromfile=/restore.json
sudo rm /dev/shm/pearl-restore.json
```

Then step 2. This path has not been rehearsed yet.

## Bumping Oyster

1. Read the release notes for the new tag at
   `github.com/pearl-research-labs/pearl/releases`.
2. Take the `pearl-linux-arm64-<tag>.tar.gz` line from that release's `checksums.txt`.
3. In `Dockerfile`, change the tag in the download URL, in both places, and the checksum.
   In `compose.yaml`, change the image tag to match. One commit.
4. Run step 2. The preflight hook refuses a tag that does not match the Dockerfile.

A build that passes but a container that exits at start with a `GLIBC_2.xx not found`
error means the new release needs a newer Debian than the base image's.
