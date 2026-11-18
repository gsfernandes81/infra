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

import os
import re
import socket
from pathlib import Path

KEY = re.compile(r"^#\s*infra-([a-z]+):\s*(.*?)\s*$")
REQUIRED = ("os", "init", "path", "name", "mode")
HEADER_SCAN_LINES = 20
HEADER_PREFIX = "# infra-"
# Documentation, not configuration. Anything else without a header is an error.
IGNORED_SUFFIXES = (".md",)
# Repo-side tooling config that lives alongside the tracked /etc copies but is not one
# of them. Named explicitly rather than matched by suffix, so a genuine /etc file that
# happens to be TOML still fails loudly for having no header.
IGNORED_NAMES = ("hw-inventory.toml",)

REPO = Path(__file__).resolve().parent.parent


def this_host():
    return socket.gethostname().split(".")[0]


def system_dir(host):
    """hosts/<host>/system, or, for a host that has only ever run Leap and so has no
    Alpine copies (three), hosts/<host>/leap/system. A host with both is still on Alpine
    until it moves, and its system/ copies are the ones that describe it."""
    alpine = REPO / "hosts" / host / "system"
    leap = REPO / "hosts" / host / "leap" / "system"
    return leap if not alpine.is_dir() and leap.is_dir() else alpine


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


# Filesystems that store no Unix mode or owner: every file's mode comes from the mount's
# fmask, chown to anyone but the mount's uid fails, and chmod fails unless it asks for the
# mode the file already has. The Pi's FAT boot partition, /boot/efi on Leap, is the case
# (three's extraconfig.txt). On these, infra-mode is what the file would be anywhere else,
# and is neither set nor checked.
MODELESS_FSTYPES = ("vfat", "msdos", "exfat")


def _unescape_mountinfo(field):
    """mountinfo escapes space, tab, newline and backslash as \\ooo."""
    return re.sub(r"\\([0-7]{3})", lambda m: chr(int(m.group(1), 8)), field)


def fs_type(path, mountinfo=None):
    """The filesystem type `path` is on (or would be, if it does not exist yet), read
    from /proc/self/mountinfo: the longest mount point that contains it. None if the
    table cannot be read. `mountinfo` is the table's text, for a test.

    Lexical, after resolving symlinks in the part of the path that exists, so a target
    under an unmounted /boot/efi reads as the root's filesystem, which is the truth: a
    write there would land in the root, under the mount point.
    """
    p, rest = Path(path), []
    while not os.path.exists(p) and p != p.parent:
        rest.insert(0, p.name)
        p = p.parent
    target = p.resolve().joinpath(*rest)
    if mountinfo is None:
        try:
            mountinfo = Path("/proc/self/mountinfo").read_text()
        except OSError:
            return None
    best, best_type = None, None
    for line in mountinfo.splitlines():
        left, sep, right = line.partition(" - ")
        if not sep:
            continue
        fields = left.split()
        if len(fields) < 5 or not right.split():
            continue
        mnt = Path(_unescape_mountinfo(fields[4]))
        if target == mnt or mnt in target.parents:
            # Later lines are later mounts, so an equal-length match over-mounts.
            if best is None or len(mnt.parts) >= len(best.parts):
                best, best_type = mnt, right.split()[0]
    return best_type


def mode_is_settable(path):
    return fs_type(path) not in MODELESS_FSTYPES


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
        if p.is_file()
        and p.suffix not in IGNORED_SUFFIXES
        and p.name not in IGNORED_NAMES
    )
