"""Shared header parsing for check-system-drift and install-system-file.

One parser, deliberately. The bug this repo just fixed was a README table and a
checker disagreeing about where a file installs; two copies of this logic would
reproduce that failure in a place nobody thinks to look.

Every tracked /etc copy carries an infra- header, present in BOTH the repo copy and
the live file. It is a comment, so it changes no behaviour, and keeping the two
byte-identical means `md5sum <tracked> <live>` stays a valid check.

    # infra-os:   alpine          distro it was written for
    # infra-init: openrc          init system it targets
    # infra-path: /etc/init.d     directory it installs into
    # infra-name: bcache-register filename there (split from the repo filename so a
    #                             MicroOS variant can install under the same name)
    # infra-mode: 0755            catches a wrong-mode install, invisible to a diff
"""

import re
import socket
from pathlib import Path

KEY = re.compile(r"^#\s*infra-([a-z]+):\s*(.*?)\s*$")
REQUIRED = ("os", "init", "path", "name", "mode")
HEADER_SCAN_LINES = 20
HEADER_PREFIX = "# infra-"
# Documentation, not configuration. Anything else without a header is an error.
IGNORED_SUFFIXES = (".md",)

REPO = Path(__file__).resolve().parent.parent


def this_host():
    return socket.gethostname().split(".")[0]


def system_dir(host):
    return REPO / "hosts" / host / "system"


def parse_header(path):
    """Return (metadata, error). Exactly one of the two is meaningful.

    A missing or malformed header is a hard failure, never a guess at the path.
    A tool that guesses is how the previous checker passed while checking nothing.
    """
    meta = {}
    try:
        with path.open("r", errors="replace") as fh:
            for _, line in zip(range(HEADER_SCAN_LINES), fh):
                m = KEY.match(line)
                if m:
                    meta[m.group(1)] = m.group(2)
    except OSError as exc:
        return None, f"cannot read: {exc}"

    if not meta:
        return None, "no infra- header (every tracked file must declare its live path)"
    missing = [k for k in REQUIRED if not meta.get(k)]
    if missing:
        return None, f"header missing required key(s): {', '.join(missing)}"
    if "/" in meta["name"]:
        return None, f"infra-name must be a bare filename, got {meta['name']!r}"
    if not meta["path"].startswith("/"):
        return None, f"infra-path must be absolute, got {meta['path']!r}"
    try:
        int(meta["mode"], 8)
    except ValueError:
        return None, f"infra-mode must be octal, got {meta['mode']!r}"
    return meta, None


def live_path(meta):
    return Path(meta["path"]) / meta["name"]


def strip_header(data: bytes) -> bytes:
    """The file as it would be without its infra- header lines."""
    keep = [ln for ln in data.split(b"\n") if not ln.startswith(HEADER_PREFIX.encode())]
    return b"\n".join(keep)


def host_init_system():
    """What this box actually runs, so a file for the wrong init is caught."""
    if Path("/run/systemd/system").is_dir():
        return "systemd"
    if Path("/run/openrc").is_dir():
        return "openrc"
    return None


def tracked_files(host):
    """Every file under hosts/<host>/system that should carry a header."""
    directory = system_dir(host)
    if not directory.is_dir():
        return None
    return sorted(
        p for p in directory.iterdir()
        if p.is_file() and p.suffix not in IGNORED_SUFFIXES
    )
