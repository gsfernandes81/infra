# VPN port forwarding

The most fragile thing on `one`. Three surprises, in the order they'll bite you.

## 1. There is no script

No cron entry, no service, no file. Port forwarding is two inline env vars on the
gluetun service in `deployments/torrents/compose.yaml`:
`VPN_PORT_FORWARDING_UP_COMMAND` / `DOWN_COMMAND`. gluetun runs the UP one itself when
Proton assigns a port, substituting `{{PORT}}` and `{{VPN_INTERFACE}}`.

**The shell escaping inside those YAML scalars is load-bearing.** It's a single-quoted
`sh -c` wrapping a double-quoted `--post-data` containing backslash-escaped JSON.
Reformat it, re-quote it, or let an editor tidy it and forwarding breaks with no error
at the time. Edit byte-for-byte or not at all.

(A missing `\` in the DOWN command meant it never reset `listen_port` to 0 — `sh` died
on an unterminated quote before `wget` ran. Fixed Aug 2026. The UP path was fine, which
is why it went unnoticed.)

## 2. It authenticates with no credentials

Not stored credentials, not an `AuthSubnetWhitelist`. A **localhost bypass**:

1. `network_mode: service:gluetun` puts qBittorrent in gluetun's network namespace
2. so gluetun's `wget` to `127.0.0.1:8080` arrives as genuine loopback
3. and `WebUI\LocalHostAuth=false` skips auth for loopback

Remove any one of the three and the hook fails silently.

**Under Podman this survives only with a shared netns** — a pod, or
`--network container:gluetun`. In Quadlet, a `.pod` unit with both containers
declaring `Pod=`. Split them and forwarding breaks with nothing in the logs.

## 3. "The port changed" does not mean it worked

```sh
grep 'Session\\Port' /media/torrents-config/qBittorrent/qBittorrent.conf
```

On restart qBittorrent immediately rewrites `Session\Port` to its own
`TORRENTING_PORT` — **6881** — seconds in, long before Proton assigns anything. Watch
for a bare change and you'll pass on that artefact and stop looking. The real sequence
during the Aug 2026 recreate:

```
43318   before
 6881   ~seconds in — qBittorrent's default, means nothing
52913   ~1 minute in — the actual forwarded port
```

**The test: differs from before *and* is not 6881.**

Same trap in the logs — gluetun's startup settings dump echoes both commands verbatim,
so any grep for "port forward" matches it and looks like an event. The dump is drawn as
a tree; filter out lines with `├ └ │`.

If the hook genuinely fails, nothing is lost — run the same `wget` by hand inside the
gluetun container.
