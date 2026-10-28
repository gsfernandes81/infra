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
# Run by ansible.builtin.script from the playbooks, on the host, as root (the docker socket).
import json
import subprocess
import sys

cfg = json.loads(subprocess.run(
    ["docker", "compose", "config", "--format", "json"],
    check=True, capture_output=True, text=True,
).stdout)
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
