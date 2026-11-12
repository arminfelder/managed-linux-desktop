# shellcheck shell=bash
# Runs on the IPA server as root (build.sh guest_run, variables ADMIN_PW FQDN IP OTP REPLACE).
# Makes the host entry of a client with a one-time password: the client joins with it (ipa-client-install --password).
# REPLACE=1 deletes an entry of the same name first: a new client build is a new device.
set -euo pipefail
export KRB5CCNAME=FILE:/var/lib/mld-ipa/host-add.cc
printf '%s' "$ADMIN_PW" | kinit admin >/dev/null
trap 'kdestroy >/dev/null 2>&1 || true' EXIT
if ipa host-show "$FQDN" >/dev/null 2>&1; then
    [ "$REPLACE" = 1 ] || { echo "host $FQDN exists (REPLACE=0)" >&2; exit 1; }
    ipa host-del "$FQDN" --updatedns >/dev/null
fi
# The OTP is the only secret of the client. It is good for one join, then the host has a keytab.
ipa host-add "$FQDN" --ip-address="$IP" --password="$OTP" >/dev/null
ipa hostgroup-add-member linux-clients --hosts="$FQDN" >/dev/null
echo "host $FQDN added (linux-clients)"
