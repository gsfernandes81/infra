# The dev containers and their hub, from a terminal on zero. **This file is their
# management interface** — the docker commands live here and nowhere else. One Compose
# project (compose.yaml, `name: dev`): the hub, its cloudflared sidecar, infra-dev, and each
# other repo's container behind its profile until it moves in.
#
#   make dev         up, then walk infra-dev through whatever is not logged in yet
#   make up          build and (re)create everything the profiles in .env name; S=<service>
#                    for one service (and the hub it depends on)
#   make restart     stop + start one container, NO re-evaluation of the config
#   make stop        stop one container (its sessions end; its volumes stay)
#   make status      one-screen health check of one container
#   make verify      status + the tools + the collections + the fleet, after a rebuild
#   make login       log a container into GitHub and claude.ai, and clone its workspace
#   make fleet       prove zero, one and two answer — by ssh, then by ansible
#   make collections check the image's collections against ansible/requirements.yml
#   make claude      the hub's menu, as `ssh dev` lands on it
#   make claude-update  update Claude Code now in one container, and say whether it updates itself
#   make shell       a login shell in one container
#   make logs        follow one container's log (= its sshd's)
#   make boot-log    one container's start-up lines, from the top
#   make tunnel-log  what the hub's cloudflared has been saying
#   make idle        what the offloader would do in every container, right now (stops nothing)
#   make offload-log what it has stopped or swept, failed passes, and the last pass
#   make sessions    claude-sessions doctor in one container: the registry, and the hooks
#   make down        stop and remove EVERY container in the project (volumes stay)
#   make down-volumes  also drop the project's own volumes — workspaces, env files, the hub key
#
# C=<container> picks the container for the targets that take one — infra-dev unless said;
# C=hub is the hub. The same targets are `make dev-up`, `make dev-login` … from the repo root.
#
# NOT runnable from an agent session: `gavin` is not in the docker group and sudo
# wants a password. This is for your own terminal on zero.
#
# The containers are USED over ssh, not from here — `ssh dev` from Termux or a PC lands on
# the hub's menu over every one of them, and a zmx session holds each claude. These targets
# stand them up and tell you what state they are in; they are not the daily interface.
# dev/README.md.

C ?= infra-dev
CONTAINER := $(if $(filter hub,$(C)),dev-hub,$(C))

# `sudo` unless already root, so both `make up` and `sudo make up` work.
SUDO := $(if $(filter 0,$(shell id -u)),,sudo)

# The uid/gid the container's `dev` user is built at, read from the OWNER of this
# checkout — not from `id -u`. Under sudo `id -u` is 0, and a dev user built at 0
# writes root-owned files into the bind-mounted clone (and collides with the base
# image's own root account at build time). The clone's owner is the right answer
# however this was invoked.
HOST_UID := $(shell stat -c '%u' $(CURDIR))
HOST_GID := $(shell stat -c '%g' $(CURDIR))

# `sudo env VAR=…`, not `VAR=… sudo`: sudo resets the environment, so an assignment in
# front of it never reaches docker and compose would silently build at the defaults in
# compose.yaml. env is inside the sudo, so it survives.
#
# COMPOSE_OVERRIDE is a second compose file layered on top, for the smoke test only
# (.github/workflows/dev-smoke.yml puts an unreleased claude-sessions into the hub's build).
# Empty on zero, always.
COMPOSE_OVERRIDE ?=
# `=`, NOT `:=`: BASE_TAG is set further down, and an immediate expansion here passed it EMPTY
# — every `make up` built at compose.yaml's fallback, which only matched by being kept in step
# by hand (found 2026-10-27; true on main since the tag moved here).
COMPOSE = $(SUDO) env HOST_UID=$(HOST_UID) HOST_GID=$(HOST_GID) BASE_TAG=$(BASE_TAG) \
	docker compose --project-directory $(CURDIR) -f $(CURDIR)/compose.yaml \
	$(if $(COMPOSE_OVERRIDE),-f $(COMPOSE_OVERRIDE))
DOCKER  := $(SUDO) docker

# The base image tag (2d). Bump it HERE when Dockerfile.base changes, then move the
# ARG BASE_TAG default in each repo's child Dockerfile as that repo is ready — children
# pin a tag, never latest, so a base rebuild cannot change a container behind its
# repo's back. THIS is the single source: COMPOSE passes it through the environment,
# compose.yaml forwards it as a build arg, the defaults in compose.yaml and
# dev/Dockerfile are fallbacks that only matter outside `make`, and
# .github/workflows/dev-base.yml reads this line to decide what to publish.
#
# THE BUMP IS WHAT PUBLISHES. Since 2026-09-21 a push to main that touches dev/ runs
# that workflow: a new tag gets built and pushed on its own, and a base change WITHOUT a
# bump fails the run rather than overwriting a tag other repos have pinned. So the order
# is bump, push, wait (about five minutes — see dev/README.md, where that number is
# measured rather than guessed), then `make up`. Or `make base` below, which builds the
# same image locally and waits for nobody.
BASE_TAG := 2026.10.26

.PHONY: help dev base up restart stop down down-volumes status verify collections logs \
	boot-log tunnel-log idle offload-log sessions login claude claude-update shell fleet \
	_require-env _require-secrets _require-uid _require-own-names

help:
	@awk '/^#/ { sub(/^# ?/, ""); print; next } { exit }' $(MAKEFILE_LIST)

# ── guards ──────────────────────────────────────────────────────────────────
# Prerequisites rather than checks inside `up`, so each says which thing is missing
# and nothing gets as far as docker with a name it cannot resolve.
# Every name in .env.example is required (its header says why), so a .env from before
# 2026-10-26 — infra-dev's alone — is refused here with the whole list, rather than by
# Compose one variable at a time.
_require-env:
	@[ -f $(CURDIR)/.env ] || { \
	  echo "no $(CURDIR)/.env — copy .env.example to .env and edit it." >&2; exit 1; }
	@missing=$$(grep -oE '^[A-Z][A-Z0-9_]*=' $(CURDIR)/.env.example | while read -r k; do \
	  grep -q "^$$k" $(CURDIR)/.env || printf ' %s' "$${k%=}"; done); \
	[ -z "$$missing" ] || { \
	  echo "dev/.env lacks:$$missing — copy each line from .env.example and set it." >&2; exit 1; }

# A container of the same name from ANOTHER compose project — infra-dev's old one, `infra-dev`,
# or a child's from its own repo — makes `up` fail half way with "name already in use",
# after the hub has started. Refuse first and name the command. `down` there, never `down -v`:
# its login volumes are this project's external ones.
_require-own-names:
	@for c in infra-dev or3-dev dd-dev dd-postgres ds-dev dev-hub dev-cloudflared; do \
	  p=$$($(DOCKER) inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' $$c 2>/dev/null) || continue; \
	  [ "$$p" = dev ] && continue; \
	  echo "container $$c belongs to compose project '$${p:-none}', not dev. Stop it there first:" >&2; \
	  echo "  cd ~ && sudo docker compose -p $$p down   # from ~, not here: this dir's compose.yaml is the new one. NOT -v" >&2; \
	  exit 1; \
	done

_require-uid:
	@[ "$(HOST_UID)" != "0" ] || { \
	  echo "refusing to build the container's dev user at uid 0: this checkout is" >&2; \
	  echo "owned by root, so every file written from the container would be too." >&2; \
	  echo "chown the clone to your own account first." >&2; exit 1; }

# Warns rather than refuses: a missing file costs the thing that uses it, and the
# container is still worth having up without it. The mode check is not cosmetic — ssh
# refuses a key it considers group- or world-readable.
_require-secrets:
	@hub=$$(grep -E '^HUB_SECRETS=' $(CURDIR)/.env | cut -d= -f2-); \
	[ -n "$$hub" ] || { echo "HUB_SECRETS is not set in .env" >&2; exit 1; }; \
	[ -s "$$hub/authorized_keys" ] || { \
	  echo "WARNING — no $$hub/authorized_keys: the hub will start and NOTHING can ssh in." >&2; \
	  echo "          ansible/playbooks/server-create-dev-container.yml -e container=dev writes it." >&2; }
	@dir=$$(grep -E '^INFRA_SECRETS=' $(CURDIR)/.env | cut -d= -f2-); \
	[ -n "$$dir" ] || { echo "INFRA_SECRETS is not set in .env" >&2; exit 1; }; \
	[ -d "$$dir" ] || { echo "INFRA_SECRETS=$$dir does not exist. From a control node:" >&2; \
	  echo "  cd ../ansible && ansible-playbook playbooks/server-create-dev-container.yml" >&2; exit 1; }; \
	missing=; \
	for f in authorized_keys id_ed25519_infra_deploy; do \
	  [ -s "$$dir/$$f" ] || missing="$$missing $$f"; \
	done; \
	[ -z "$$missing" ] || { \
	  echo "WARNING — missing or empty in $$dir:$$missing" >&2; \
	  echo "          The container will start; whatever needs those will not work." >&2; \
	  echo "          ansible/playbooks/server-create-dev-container.yml writes both." >&2; }; \
	[ -s "$$dir/id_ed25519_fleet" ] || \
	  echo "note: no fleet access configured (the default) — the container has no route" >&2; \
	[ ! -s "$$dir/id_ed25519_fleet" ] || \
	  echo "note: fleet access IS configured — this container can reach all three hosts" >&2; \
	mode=$$(stat -c %a "$$dir"); \
	[ "$$mode" = 700 ] || echo "WARNING — $$dir is mode $$mode, expected 700." >&2

# ── lifecycle ───────────────────────────────────────────────────────────────
# The OFFLINE FALLBACK for the base image. The normal path is a pull: the child's
# FROM names ghcr.io/gsfernandes81/gsrpi-dev-base, public, built by
# .github/workflows/dev-base.yml. This target builds the identical image locally UNDER
# THE GHCR NAME — docker prefers a local image over a pull, so after `make base` the
# child builds with no GitHub. Use it when GitHub is down, the month is metered, or this
# host's uid differs from the 1001 the CI image bakes.
#
# IDENTICAL BUT FOR CRUSH, which is the latest release on the day it is built, not a pin:
# crush-latest asks GitHub which one, and the build fetches it from repo.charm.sh. So a
# `make base` days after CI built the same tag can carry a newer Crush, and with either of
# those down this needs `make base CRUSH_VERSION=none`, which builds without it.
# Dockerfile.base, the Crush layer, has the reasons.
base: _require-uid
	@ver='$(CRUSH_VERSION)'; \
	if [ -z "$$ver" ]; then ver=$$($(CURDIR)/crush-latest) || exit 1; fi; \
	echo "base $(BASE_TAG), crush $$ver"; \
	$(DOCKER) build -f $(CURDIR)/Dockerfile.base \
	  --build-arg USER_UID=$(HOST_UID) --build-arg USER_GID=$(HOST_GID) \
	  --build-arg CRUSH_VERSION="$$ver" \
	  -t ghcr.io/gsfernandes81/gsrpi-dev-base:$(BASE_TAG) $(CURDIR)

# No `base` dependency: the FROM pulls from ghcr when the tag is absent locally, so
# the cross-repo build order 2d started with is gone — that was the point of the
# registry. `make base` above exists for the days the registry does not.
up: _require-env _require-uid _require-secrets _require-own-names
	$(COMPOSE) up -d --build $(S)
	@printf '\n'
	@$(MAKE) --no-print-directory status

# One command from nothing: build, start, wait for the container to answer, then walk
# through the logins that are not done. Every step of login.sh is idempotent, so this
# is also the safe thing to run when you are not sure what state it is in.
dev: up
	@echo; echo "Waiting for $(CONTAINER) to answer (up to 60s)..."
	@for i in $$(seq 1 60); do \
	  $(DOCKER) exec $(CONTAINER) true 2>/dev/null && break; \
	  [ $$i = 60 ] && { echo "ERROR: $(CONTAINER) never became exec-able — make boot-log" >&2; exit 1; }; \
	  sleep 1; \
	done
	@$(MAKE) --no-print-directory login

# stop + start, deliberately NOT `up -d`. `up` re-evaluates compose.yaml and may
# recreate the container, which drops every session in it. The corollary: a
# change to compose.yaml — ports, limits, environment — lands only on `up`.
restart:
	$(DOCKER) stop  $(CONTAINER)
	$(DOCKER) start $(CONTAINER)
	@printf '\n'
	@$(MAKE) --no-print-directory status

# One container down, the rest and the hub untouched. Its sessions end with it; `make up`
# or `make restart` brings it back.
stop:
	$(DOCKER) stop $(CONTAINER)

down:
	$(COMPOSE) down

# The project's OWN volumes: each cloned workspace, each env-file volume, the shared
# claude-sessions volume and the hub's key, known_hosts and host key. NOT the logins, history
# and host keys of the containers that moved in — those are external volumes kept from each
# container's old project, and `down -v` leaves an external volume alone. Dropping these
# means re-cloning (unpushed work in a workspace goes with it), rewriting each env file, and
# a new hub key, which every container authorises again at its next start.
down-volumes:
	@[ "$(CONFIRM)" = yes ] || { \
	  echo "This drops the dev project's own volumes:" >&2; \
	  echo "  - every cloned /workspace — UNPUSHED WORK IN ONE IS LOST" >&2; \
	  echo "  - every env-file volume (~/.env.d) — the repos' .env files" >&2; \
	  echo "  - the hub's key and known_hosts; containers re-authorise a new one at start" >&2; \
	  echo "  - the hub's HOST key: every client's known_hosts entry for 'ssh dev' then refuses it" >&2; \
	  echo "Logins, conversation history and container host keys are external and stay." >&2; \
	  echo "Say you mean it:  make down-volumes CONFIRM=yes" >&2; exit 1; }
	$(COMPOSE) down -v

# ── readouts ────────────────────────────────────────────────────────────────
# status.sh is one script rather than several recipes because these are long, and a
# health check spelled in Makefile line-continuations is a health check nobody will
# correct. It reads the container and prints; it changes nothing.
status verify collections boot-log fleet:
	@SUDO="$(SUDO)" CONTAINER=$(CONTAINER) bash $(CURDIR)/status.sh $@

tunnel-log:
	$(DOCKER) logs --tail 60 dev-cloudflared

logs:
	$(DOCKER) logs -f --tail 100 $(CONTAINER)

# The offloader's own two questions, asked of the hub, which runs it for every container.
# `idle` is a DRY RUN in every container at once — each one's verdict on each slot now,
# nothing stopped (a dry run still writes the activity state, so the loop's next window may
# be too short to count). `offload-log` is what the live loop has done: real stops and the
# sweep from one container's own offload.log, then failed passes and the last pass from the
# hub's pass log.
idle:
	$(DOCKER) exec dev-hub claude-sessions offload-all --dry-run

offload-log:
	@echo '── $(CONTAINER): offload.log (real stops, and the orphan sweep) ──'
	@$(DOCKER) exec $(CONTAINER) sh -c 'tail -n 40 /home/dev/.local/share/claude-sessions/offload.log 2>/dev/null || echo "nothing offloaded yet"'
	@echo '── failed passes (the hub) ──'
	@$(DOCKER) exec dev-hub sh -c 'f=/home/dev/.hub/passes.log; t=$$(grep -h "pass failed" "$$f" 2>/dev/null | tail -n 5 | cut -d" " -f1); [ -n "$$t" ] || { echo "none"; exit 0; }; for s in $$t; do grep -F "$$s" "$$f"; done'
	@echo '── the last pass (the hub) ──'
	@$(DOCKER) exec dev-hub sh -c 'f=/home/dev/.hub/passes.log; [ -f "$$f" ] && grep -F "$$(tail -n 1 "$$f" | cut -d" " -f1)" "$$f" || echo "no pass yet"'

# Read-only. "events: none seen" on a slot means the hooks are not firing — the first
# thing to check after a rebuild, since a hooks file Claude Code ignored says nothing.
sessions:
	$(DOCKER) exec $(CONTAINER) claude-sessions doctor

# ── into the container ──────────────────────────────────────────────────────
# The interactive half. All three are `docker exec -it`, which is the way in from
# ZERO; from the phone or a PC the way in is ssh, and those have ssh equivalents
# printed at the end of login.sh.
login:
	$(DOCKER) exec -it $(CONTAINER) bash /home/dev/login.sh

# The hub's menu, the same one `ssh dev` lands on, so it lists the same sessions whichever
# way you came in: Enter on a container shows its sessions, Enter on one attaches or
# resumes it, `n` starts another, `q` leaves. Each session is a zmx session: Ctrl-\
# detaches, the menu comes back, and the claude keeps running.
claude:
	$(DOCKER) exec -it dev-hub claude-sessions

# The container's own login shell — fish in infra-dev, bash in the hub — from passwd, as
# sshd would pick it.
shell:
	$(DOCKER) exec -it $(CONTAINER) sh -c 'exec "$$(getent passwd "$$(id -u)" | cut -d: -f7)" -l'

# Claude Code updates ITSELF in the background and the new version takes effect at the
# next `claude`, so this is not how it normally moves — it is how you move it NOW,
# without waiting for a session to notice, and how you see what state the mechanism is
# in. The second command is the readout, and the line to look for is `Can't auto-update`,
# NOT `Auto-updates: enabled` — measured 2026-09-21, the latter says `enabled` even on an
# install that cannot write its own directory and will never move. status.sh's
# `autoupdate` line explains that at length; this prints both and lets you read them.
#
# Not `-it`: both commands print and exit, and a tty here would only matter if one of
# them decided to ask something, which is exactly what a management target should not do.
claude-update:
	$(DOCKER) exec $(CONTAINER) claude update
	$(DOCKER) exec $(CONTAINER) sh -c \
	  "claude doctor 2>/dev/null | grep -E \"^(Auto-updates|Auto-update channel|Last update attempt):|Can't auto-update\"" \
	  || echo "claude doctor said nothing about updating — run it in the container: make shell"
