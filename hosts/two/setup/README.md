# `two` — host setup

Raspberry Pi 1 B+ · ARMv6 · 512 MB · Alpine · OpenRC · rootless podman.

Run every command as **root** unless a step says otherwise. Steps are ordered; 1–9 are
one-time, 10 is the deploy.

---

## 1. Packages

```sh
apk add --no-cache \
    podman podman-compose crun conmon netavark aardvark-dns \
    passt shadow-subids catatonit fuse-overlayfs \
    iptables git zram-init ca-certificates
```

## 2. Kernel modules

```sh
modprobe tun
modprobe fuse
for m in tun fuse; do grep -qx "$m" /etc/modules || echo "$m" >> /etc/modules; done
```

Without `tun`, every rootless container with a network fails at start.

## 3. zram swap

```sh
modprobe zram
echo lz4  > /sys/block/zram0/comp_algorithm
echo 256M > /sys/block/zram0/disksize
mkswap /dev/zram0
swapon -p 100 /dev/zram0

cat > /etc/sysctl.d/60-zram.conf <<'EOF'
vm.swappiness = 100
vm.page-cluster = 0
EOF
sysctl -p /etc/sysctl.d/60-zram.conf
```

Persist across reboots:

```sh
cat > /etc/local.d/zram.start <<'EOF'
#!/bin/sh
modprobe zram
echo lz4  > /sys/block/zram0/comp_algorithm
echo 256M > /sys/block/zram0/disksize
mkswap /dev/zram0
swapon -p 100 /dev/zram0
EOF
chmod +x /etc/local.d/zram.start
rc-update add local default
```

## 4. Deploy user

```sh
addgroup deploy
adduser -D -s /bin/sh claude
adduser claude deploy
adduser gavin  deploy
```

`claude` must **not** be in `wheel`.

## 5. subuid / subgid

```sh
echo 'claude:165536:65536' >> /etc/subuid
echo 'claude:165536:65536' >> /etc/subgid
```

Ranges must not overlap `gavin`'s (`100000:65536`).

## 6. Runtime directory and OOM priority

```sh
cat > /home/claude/.profile <<'EOF'
export XDG_RUNTIME_DIR="/tmp/podman-run-$(id -u)"
mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"
echo 500 > /proc/self/oom_score_adj 2>/dev/null || true
EOF
chown claude:claude /home/claude/.profile
```

Everything `claude` starts from a login shell inherits `oom_score_adj=500`, containers
included. Non-login invocations (`ssh claude@host 'cmd'`) do not read `.profile` — use
`ssh claude@host -t 'sh -lc "cmd"'` when it matters.

## 7. Protect cloudflared from the OOM killer

```sh
cat > /etc/local.d/oom.start <<'EOF'
#!/bin/sh
for d in /proc/[0-9]*; do
    [ "$(cat "$d/comm" 2>/dev/null)" = cloudflared ] && echo -1000 > "$d/oom_score_adj"
done
exit 0
EOF
chmod +x /etc/local.d/oom.start
rc-update add local default
/etc/local.d/oom.start
```

Do not use `pgrep -x cloudflared` — busybox `pgrep` matches the full `argv[0]` path, not
`comm`, and finds nothing.

## 8. Firewall

The box needs the gateway and the internet. It does not need the rest of the LAN.

```sh
# egress
iptables -A OUTPUT -d 192.168.86.1     -j ACCEPT
iptables -A OUTPUT -d 10.89.0.0/16     -j ACCEPT
iptables -A OUTPUT -d 192.168.86.0/24  -j REJECT --reject-with icmp-host-unreachable
iptables -A OUTPUT -d 10.0.0.0/8       -j REJECT
iptables -A OUTPUT -d 172.16.0.0/12    -j REJECT

# ingress — access is via the cloudflare tunnel, which is outbound
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -s 192.168.86.0/24 -j DROP

/etc/init.d/iptables save
rc-update add iptables default
```

Do **not** block `169.254.0.0/16` — pasta uses it for container DNS.

To scope egress rules to the deploy account only, append `-m owner --uid-owner claude`
to each `OUTPUT` rule. Rootless container traffic is emitted by `pasta` running as that
user, so it matches.

## 9. Repo checkout

One clone, in neither home directory. `gavin` writes, `claude` reads.

```sh
install -d -o gavin -g deploy -m 2750 /srv
```

As **gavin**:

```sh
git clone git@github.com:gsfernandes81/infra.git /srv/infra
```

As root:

```sh
chgrp -R deploy /srv/infra
find /srv/infra -type d -exec chmod 2750 {} +
find /srv/infra -type f -exec chmod 0640 {} +
```

`claude` cannot edit `compose.yaml`, so it cannot change which image deploys.

## 10. SSH access

Append to `/etc/ssh/sshd_config`:

```
Match User claude
    DisableForwarding yes
    PermitTunnel no
    X11Forwarding no
```

```sh
rc-service sshd restart
install -d -o claude -g claude -m 0700 /home/claude/.ssh
# paste the public key:
echo 'ssh-ed25519 AAAA... claude@two' > /home/claude/.ssh/authorized_keys
chown claude:claude /home/claude/.ssh/authorized_keys
chmod 600 /home/claude/.ssh/authorized_keys
```

Connect with `ssh claude@ssh-two.gsrpi.uk` (client needs
`ProxyCommand cloudflared access ssh --hostname %h`).

---

## Environment file

`/srv/infra/deployments/destiny-director/.env` is not in git. Create it from
`.env.example` as **gavin**, then:

```sh
chgrp deploy .env && chmod 0640 .env
```

Every member of `deploy` can read it. Keep the group to `gavin` and `claude`.

---

## Deploy

As **claude**:

```sh
cd /srv/infra/deployments/destiny-director
podman-compose pull
podman-compose up -d postgres
podman-compose up -d --no-deps --force-recreate beacon
podman-compose up -d --no-deps --force-recreate anchor
```

`--no-deps` is required. Without it `--force-recreate` destroys `postgres` through
`depends_on`; on a fresh volume that kills `initdb` mid-run and the cluster is
unrecoverable.

`cd` first. podman-compose reads a `.env` from the current directory and lets it win.

### Other operations

```sh
podman-compose down                       # never with --volumes
podman start dd-postgres dd-beacon dd-anchor   # after a reboot, no pull
rc-service podman start_containers        # same, by restart policy
podman logs --tail 200 dd-beacon
podman logs --tail 200 dd-anchor
podman logs --tail 200 dd-postgres
podman stats --no-stream
podman system df                          # nothing prunes; check periodically
```

A bot is online when its log prints `started successfully in approx`. Cold start on this
board is 5–6 minutes.

---

## Verify

| Command | Expect |
|---|---|
| `podman info --format '{{.Store.GraphDriverName}}'` | `overlay`, not `vfs` |
| `podman info --format '{{.Host.OCIRuntime.Name}}'` | `crun` |
| `podman info --format '{{.Host.NetworkBackend}}'` | `netavark` |
| `podman info --format '{{.Host.Security.Rootless}}'` | `true` |
| `ls -l /dev/net/tun` | exists |
| `swapon --show` or `cat /proc/swaps` | `/dev/zram0` |
| `id claude` | no `wheel` |
| `ping -c1 192.168.86.1` | replies |
| `ping -c1 192.168.86.103` | rejected |
| `podman exec dd-beacon getent hosts discord.com` | resolves |
| `readelf -A <any .so> \| grep Tag_CPU_arch` | `v6`, never `v7` |

---

## Recovery

| Symptom | Fix |
|---|---|
| No SSH after a reboot | Nothing starts at boot by design. Containers: `rc-service podman start_containers`. If cloudflared is down, console or SD card only. |
| `pasta failed: Failed to open() /dev/net/tun` | `modprobe tun` — step 2 did not persist. |
| Bot loops on `Database unavailable` | `podman exec dd-postgres psql -U dd -d template1 -Atc 'select datname from pg_database'`. If `kyber` is missing, initdb was interrupted: `podman-compose down; podman volume rm destiny-director_pgdata`, then deploy again. |
| Bot takes SIGSEGV shortly after start | An ARMv7 binary on an ARMv6 core. Check with `readelf -A`; rebuild the image. |
| Deploy hangs or the box swaps hard | Only one deploy at a time. |
