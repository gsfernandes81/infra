# shellcheck shell=bash
# shellcheck disable=SC2016  # the checks are shell code for sh -c, quoted on purpose
# one's own checks, appended to checks.sh by run-host.sh, so check and docker_checks are
# defined: Docker on its new store on the SSD.

echo "-- Docker"
check "Docker runs, on the store on the SSD" sh -c '
	systemctl is-active docker && findmnt -no SOURCE /var/lib/docker | tee /dev/stderr | grep -q "/var-lib-docker-leap"'
docker_checks
