#!/bin/bash
# Runs in the VM over ssh, once: the commands the hosts' cloudflared plugin will rely on,
# against openSUSE's package, with a config shaped as the fleet's and no credentials.
set -u
run() { printf '$ %s\n' "$*"; "$@" 2>&1; printf '[exit %s]\n' "$?"; }
run rpm -q cloudflared health-checker
run cloudflared --version
run sh -c 'rpm -ql cloudflared | grep -vE "/man/|/doc/|/licenses/"'
run sh -c 'systemctl cat cloudflared.service 2>&1 | head -n 25'
mkdir -p /root/cf
cat > /root/cf/config.yml <<'YAML'
tunnel: 00000000-0000-4000-8000-000000000000
credentials-file: /root/cf/creds.json
metrics: 127.0.0.1:20241
no-autoupdate: true
ingress:
  - hostname: ssh-sim.example.invalid
    service: ssh://127.0.0.1:22
  - service: http_status:404
YAML
run cloudflared tunnel --config /root/cf/config.yml ingress validate
run cloudflared tunnel --config /root/cf/config.yml ingress rule https://ssh-sim.example.invalid
echo "-- and one that must fail, so the check is shown able to:"
printf 'ingress:\n  - service: ssh://127.0.0.1:22\n  - hostname: late.example.invalid\n    service: http_status:404\n' \
	> /root/cf/bad.yml
run cloudflared tunnel --config /root/cf/bad.yml ingress validate
echo "-- what the package's binary does when asked to update itself:"
run timeout 60 cloudflared update
run sh -c 'ls /usr/libexec/health-checker/ /usr/local/libexec/health-checker/ 2>&1'
run sh -c 'ls /boot/efi/loader/entries 2>&1 | head; cat /etc/sysconfig/bootloader 2>/dev/null | grep -E "^LOADER_TYPE"'
