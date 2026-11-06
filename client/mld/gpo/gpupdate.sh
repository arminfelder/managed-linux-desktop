#!/bin/bash
# Group Policy for the Linux client, as root (mld-gpupdate.service, every 90 min and at boot).
# First the CA certificates from AD (mld-cert ca), so that the browsers trust them, then the GPOs (samba-gpupdate).
# Arguments go to samba-gpupdate, for example --rsop or --force.
set -euo pipefail
if [ -r /etc/mld-cert.conf ]; then /usr/local/sbin/mld-cert ca; fi
# samba-gpupdate finds the DC with one SRV query and does not try again.
# The query fails while systemd-resolved restarts (phase_dns), so wait for the record.
conf=/etc/mld/gpo/gpupdate.conf
realm=$(awk -F' *= *' '$1 ~ /^[[:space:]]*realm$/ { print $2 }' "$conf")
for _ in $(seq 1 30); do
    resolvectl query -t SRV "_ldap._tcp.$realm" >/dev/null 2>&1 && break
    sleep 2
done
exec /usr/sbin/samba-gpupdate -s "$conf" "$@"
