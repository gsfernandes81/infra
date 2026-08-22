# infra, from the repo root.
#
#   make dev         stand up the infra-dev container on zero and walk the logins
#   make dev-up      build + (re)create it
#   make dev-status  one-screen health check
#   make dev-verify  status + tools + collections + the fleet
#   make dev-login   re-run the logins
#   make dev-fleet   prove zero, one and two answer
#   make dev-shell   a fish shell in it
#   make dev-claude  attach its `claude` abduco session
#   make dev-tunnel-log  what cloudflared is saying, if the tunnel is on
#   make dev-logs / dev-boot-log / dev-restart / dev-down
#
# Everything above forwards into dev/Makefile, which is where the docker commands
# live. Nothing here is runnable from an agent session: `gavin` is not in the docker
# group and sudo wants a password.
#
# THESE RUN LOCALLY, so they only work ON the host running the container — zero. From
# the phone there is nothing to forward to and docker is simply absent; reach them over
# ssh instead, which is the documented way and needs nothing new:
#
#     ssh -t zero 'cd ~/infra/dev && make up'
#
# Not wrapped in an ssh-if-not-zero rule here on purpose: a Makefile that silently does
# something different depending on which machine you are on is worse than one that fails
# with "docker: not found".
#
# The bin/ programs are deliberately NOT wrapped here yet. Wrapping them is wanted —
# `make` is the management interface everywhere else in this fleet's repos — but
# check-sources, check-system-drift, install-system-file and check-mount-guards take
# arguments and flags that a bare target would have to invent names for, and a name
# invented here is a second interface to keep in step with the one in bin/. Do it as
# its own change, with the argument shapes decided rather than papered over.

# Named rather than pattern-matched, so `make dev-<typo>` is an error here instead of
# a confusing one two directories down. It is also what makes .PHONY work: make does
# not apply implicit rules to a phony target, so a bare `dev-%:` pattern silently
# matches nothing and prints "Nothing to be done".
DEV_TARGETS := up restart down down-volumes status verify collections login fleet \
	claude shell logs boot-log tunnel-log

.PHONY: help dev $(addprefix dev-,$(DEV_TARGETS))

help:
	@awk '/^#/ { sub(/^# ?/, ""); print; next } { exit }' $(firstword $(MAKEFILE_LIST))

# `dev` keeps its own name — `make dev-dev` is nobody's idea of a target. It must stay
# phony for a second reason too: there is a directory called dev, and without .PHONY
# make would call the target up to date because the directory exists.
dev:
	@$(MAKE) --no-print-directory -C dev dev

# A static pattern rule: strip the `dev-` prefix and hand the rest to dev/Makefile,
# which is the only place the docker commands are spelled.
$(addprefix dev-,$(DEV_TARGETS)): dev-%:
	@$(MAKE) --no-print-directory -C dev $*
