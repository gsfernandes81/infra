# shellcheck shell=bash
# shellcheck disable=SC2016  # the checks are shell code for sh -c, quoted on purpose
# one's own checks, appended to checks.sh by run-host.sh, so check and docker_checks are
# defined: Docker on its new store on the SSD, and the dev stack's group and secrets.

echo "-- Docker"
check "Docker runs, on the store on the SSD" sh -c '
	systemctl is-active docker && findmnt -no SOURCE /var/lib/docker | tee /dev/stderr | grep -q "/var-lib-docker-leap"'
docker_checks

echo "-- the dev stack's group"
check "devstack is gid 1001 and gavin is in it" sh -c '
	getent group devstack | tee /dev/stderr | grep -qE "^devstack:[^:]*:1001:(.*,)?gavin(,|$)"'
# The secrets directory dev's .env names, as the play leaves a carried one (decisions.md §
# The dev stack runs as 1001 on every host). make-stick --new carries none.
if [ "${EXPECT_NEW_HOST:-}" != yes ]; then
	check "the dev stack's carried secrets are gavin's, group 1001, 0750 and 0640" sh -c '
		d=/home/gavin/.dev-secrets; find "$d" -printf "%m %u %G %p\n" | tee /dev/stderr | grep -q " $d/" &&
		! find "$d" \( ! -user gavin -o ! -gid 1001 -o -type d ! -perm 750 -o -type f ! -perm 640 \) | grep -q .'
fi
