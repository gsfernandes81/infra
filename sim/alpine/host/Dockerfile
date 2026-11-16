# A stand-in for an Alpine fleet host, for sim/alpine/run-setup-plays.sh: Alpine with OpenRC
# as init, sshd, and the packages zero has that the setup plays touch. gavin logs in by key
# and has sudo without a password, so the plays run without -K. Never run anywhere but a
# throwaway CI runner: it is privileged, and that password-less sudo is the opposite of the
# fleet's.
#
# The Alpine release zero runs (docs/fleet-inventory.md), pinned by digest.
FROM alpine:3.24@sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf

# log_proxy came to zero with Docker, and the tracked tailscaled logs through it. iptables
# and iproute2 are in base_packages, and the real tailscaled reaches for both.
RUN apk add --no-cache openrc openssh python3 sudo git \
        curl iptables ip6tables iproute2 log_proxy

# OpenRC as a container's init: no gettys, no hardware services, and `net` provided, which
# nothing configures here but the tracked services need.
RUN sed -i 's/^tty/#tty/' /etc/inittab \
 && printf '%s\n' 'rc_sys="docker"' 'rc_provide="loopback net"' 'rc_env_allow="*"' >> /etc/rc.conf \
 && rm -f /etc/init.d/hwdrivers /etc/init.d/hwclock /etc/init.d/modules /etc/init.d/modloop \
 && ssh-keygen -A \
 && rc-update add sshd default

# adduser -D locks the account, and sshd refuses a key for a locked one. The host checkout
# is cloned from a repository the runner owns, hence safe.directory.
RUN adduser -D -s /bin/sh gavin \
 && sed -i 's/^gavin:!/gavin:*/' /etc/shadow \
 && echo 'gavin ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/gavin \
 && install -d -o gavin -g gavin -m 700 /home/gavin/.ssh \
 && git config --system safe.directory '*'

CMD ["/sbin/init"]
