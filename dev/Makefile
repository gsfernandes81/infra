# infra-dev, from a terminal on zero. **This file is the container's management
# interface** — the docker commands live here and nowhere else.
#
#   make dev         up, then walk through whatever is not logged in yet
#   make up          build the image and (re)create the container
#   make restart     stop + start, NO re-evaluation of the config
#   make status      one-screen health check
#   make verify      status + the tools + the collections + the fleet, after a rebuild
#   make login       log this container into GitHub and claude.ai (idempotent)
#   make fleet       prove zero, one and two answer — by ssh, then by ansible
#   make collections check the image's collections against ansible/requirements.yml
#   make claude      a claude in the container's `claude` abduco session
#   make shell       a fish shell in the container
#   make logs        follow the container log (= sshd's)
#   make boot-log    the entrypoint's start-up lines, from the top
#   make down        stop and remove the container (volumes stay)
#   make down-volumes  also drop the volumes — logins and host key go with them
#
# The same targets are `make dev-up`, `make dev-login` … from the repo root.
#
# NOT runnable from an agent session: `gavin` is not in the docker group and sudo
# wants a password. This is for your own terminal on zero.
#
# The container is USED over ssh, not from here — `ssh infra-dev` from Termux or a PC,
# and `abduco` to hold the session. These targets stand it up and tell you what state
# it is in; they are not the daily interface. dev/README.md.

CONTAINER := infra-dev

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
COMPOSE := $(SUDO) env HOST_UID=$(HOST_UID) HOST_GID=$(HOST_GID) \
	docker compose --project-directory $(CURDIR) -f $(CURDIR)/compose.yaml
DOCKER  := $(SUDO) docker

.PHONY: help dev up restart down down-volumes status verify collections logs \
	boot-log login claude shell fleet _require-env _require-secrets _require-uid

help:
	@awk '/^#/ { sub(/^# ?/, ""); print; next } { exit }' $(MAKEFILE_LIST)

# ── guards ──────────────────────────────────────────────────────────────────
# Prerequisites rather than checks inside `up`, so each says which thing is missing
# and nothing gets as far as docker with a name it cannot resolve.
_require-env:
	@[ -f $(CURDIR)/.env ] || { \
	  echo "no $(CURDIR)/.env — copy .env.example to .env and edit it." >&2; exit 1; }

_require-uid:
	@[ "$(HOST_UID)" != "0" ] || { \
	  echo "refusing to build the container's dev user at uid 0: this checkout is" >&2; \
	  echo "owned by root, so every file written from the container would be too." >&2; \
	  echo "chown the clone to your own account first." >&2; exit 1; }

# Warns rather than refuses: a missing file costs the thing that uses it, and the
# container is still worth having up without it. The mode check is not cosmetic — ssh
# refuses a key it considers group- or world-readable.
_require-secrets:
	@dir=$$(grep -E '^INFRA_SECRETS=' $(CURDIR)/.env | cut -d= -f2-); \
	[ -n "$$dir" ] || { echo "INFRA_SECRETS is not set in .env" >&2; exit 1; }; \
	[ -d "$$dir" ] || { echo "INFRA_SECRETS=$$dir does not exist. Run ./seed-secrets.sh first." >&2; exit 1; }; \
	missing=; \
	for f in authorized_keys id_ed25519_infra_deploy id_ed25519_fleet ssh_config.fleet known_hosts.fleet; do \
	  [ -s "$$dir/$$f" ] || missing="$$missing $$f"; \
	done; \
	[ -z "$$missing" ] || { \
	  echo "WARNING — missing or empty in $$dir:$$missing" >&2; \
	  echo "          The container will start; whatever needs those will not work." >&2; \
	  echo "          ./seed-secrets.sh writes all five." >&2; }; \
	mode=$$(stat -c %a "$$dir"); \
	[ "$$mode" = 700 ] || echo "WARNING — $$dir is mode $$mode, expected 700." >&2

# ── lifecycle ───────────────────────────────────────────────────────────────
up: _require-env _require-uid _require-secrets
	$(COMPOSE) up -d --build
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
# recreate the container, which drops every abduco session in it. The corollary: a
# change to compose.yaml — ports, limits, environment — lands only on `up`.
restart:
	$(DOCKER) stop  $(CONTAINER)
	$(DOCKER) start $(CONTAINER)
	@printf '\n'
	@$(MAKE) --no-print-directory status

down:
	$(COMPOSE) down

# The volumes hold the claude login, the gh login, the sshd HOST key and the shell
# history. Dropping them means logging in again and every client being asked to accept
# a changed host key — which is the moment a real key change would be waved through.
# So it takes a word on the command line, not just a target name.
down-volumes:
	@[ "$(CONFIRM)" = yes ] || { \
	  echo "This drops infra-claude, infra-gh, infra-ssh-host and infra-local-share:" >&2; \
	  echo "  - claude and gh logins go, and must be done again (make login)" >&2; \
	  echo "  - the sshd host key goes, so the phone and any PC will be asked to" >&2; \
	  echo "    accept a new one — clear their known_hosts entry yourself" >&2; \
	  echo "Say you mean it:  make down-volumes CONFIRM=yes" >&2; exit 1; }
	$(COMPOSE) down -v

# ── readouts ────────────────────────────────────────────────────────────────
# status.sh is one script rather than several recipes because these are long, and a
# health check spelled in Makefile line-continuations is a health check nobody will
# correct. It reads the container and prints; it changes nothing.
status verify collections boot-log fleet:
	@SUDO="$(SUDO)" CONTAINER=$(CONTAINER) bash $(CURDIR)/status.sh $@

logs:
	$(DOCKER) logs -f --tail 100 $(CONTAINER)

# ── into the container ──────────────────────────────────────────────────────
# The interactive half. All three are `docker exec -it`, which is the way in from
# ZERO; from the phone or a PC the way in is ssh, and those have ssh equivalents
# printed at the end of login.sh.
login:
	$(DOCKER) exec -it $(CONTAINER) bash /home/dev/login.sh

# `abduco -A`: attach the session named `claude`, creating it if it is not there. So
# this is the same command whether you are starting the work or coming back to it, and
# it is the same session `ssh -t infra-dev abduco -A claude claude` reaches from the
# phone — one session, not one per way in. Ctrl-\ detaches; the claude under it keeps
# running, container and all.
claude:
	$(DOCKER) exec -it $(CONTAINER) abduco -A claude claude

shell:
	$(DOCKER) exec -it $(CONTAINER) fish
