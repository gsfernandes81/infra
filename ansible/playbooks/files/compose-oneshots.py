#!/usr/bin/env python3
# Print the container name of every ONE-SHOT in the compose project of the current directory,
# one per line: a service some other service waits on with
# `depends_on: <svc>: condition: service_completed_successfully` (dev's `policy`, which installs
# the managed CLAUDE.md as root and exits). Such a service reads `Exited (0)` when it has done its
# job, and `up` runs it again every time, so the deploy and stop/start plays treat it apart from
# every other container, which they require to be Up.
#
# Read from `docker compose config` and not from the repo's compose.yaml: the daemon's view has
# the merge keys resolved, every `depends_on` in its long form, `.env` interpolated, and the
# project name as Compose will use it (COMPOSE_PROJECT_NAME beats `name:`), so the fallback
# `<project>-<service>-1` is the name `compose ps` prints. That output carries every
# interpolated secret, so it is read here and only names leave: never print or save it.
#
# Docker Compose 5.6.1, which zero runs, cannot serialise a project whose service has a
# `build.ssh` entry (dev's `or3`): `config --format json` exits 1 with `error calling
# MarshalJSON for type types.SSHKey`. Compose 2.38 does not have the bug, so the plain read is
# tried first, as it always was. On failure it is retried with a throwaway override file that
# resets `build.ssh` on every service, which makes 5.6.1 serialise. The reset gives an image-only
# service an empty `build` section in the read, which this script never looks at. The override
# is written to a 0600 file in a fresh temp directory and removed afterwards; it holds service
# names and nothing else. It is passed as the second `-f` after `compose.yaml`, the name every
# deployment here uses.
#
# When both reads fail, Compose's stderr (never its stdout) goes to this script's stderr and the
# exit is non-zero, because a `CalledProcessError` traceback shows the exit status and not the
# reason, and the play that ran this printed no cause at all.
#
# A retry that succeeds prints nothing. The play's `-tt` channel merges stderr into stdout, and
# every line of output is read as a container name, so a note on the success path became a
# one-shot that "did not run in this up" and failed a deploy that had worked.
#
# Run by ansible.builtin.script from the playbooks, on the host, as root (the docker socket).
import json
import os
import shutil
import subprocess
import sys
import tempfile

CONFIG = ["docker", "compose"]


def compose(*args):
    return subprocess.run(
        CONFIG + list(args), capture_output=True, text=True, check=False,
    )


def last_line(text):
    lines = [l for l in text.strip().splitlines() if l.strip()]
    return lines[-1] if lines else "no message"


def read_config():
    plain = compose("config", "--format", "json")
    if plain.returncode == 0:
        return json.loads(plain.stdout)

    listed = compose("config", "--services")
    if listed.returncode != 0:
        sys.stderr.write(listed.stderr)
        sys.exit(1)
    override = "services:\n" + "".join(
        f"  {name}:\n    build:\n      ssh: !reset []\n"
        for name in listed.stdout.split()
    )
    tmp = tempfile.mkdtemp()
    try:
        path = os.path.join(tmp, "reset-build-ssh.yaml")
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(override)
        retry = compose("-f", "compose.yaml", "-f", path, "config", "--format", "json")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    if retry.returncode != 0:
        sys.stderr.write(
            f"compose-oneshots: plain config read failed: {last_line(plain.stderr)}\n"
            f"compose-oneshots: retry with build.ssh reset failed:\n{retry.stderr}"
        )
        sys.exit(1)
    return json.loads(retry.stdout)


cfg = read_config()
services = cfg.get("services") or {}
names = set()
for svc in services.values():
    deps = svc.get("depends_on") or {}
    if not isinstance(deps, dict):
        continue
    for dep, cond in deps.items():
        if isinstance(cond, dict) and cond.get("condition") == "service_completed_successfully":
            target = services.get(dep) or {}
            names.add(target.get("container_name") or f"{cfg['name']}-{dep}-1")
sys.stdout.write("".join(n + "\n" for n in sorted(names)))
