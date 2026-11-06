#!/bin/bash
# Reboot after updates, at night (mld-reboot.timer). Only when a reboot is necessary and no user session is open.
set -euo pipefail
[ -e /run/reboot-required ] || exit 0
# Without TPM2 unlock, the client stops at the LUKS passphrase prompt.
if ! grep -qs 'tpm2-device=' /etc/crypttab; then
    echo "reboot required, but the disk has no TPM2 unlock: reboot by hand"
    exit 0
fi
for u in mld-firstboot.service apt-daily-upgrade.service; do
    if systemctl -q is-active "$u"; then echo "reboot required, but $u runs"; exit 0; fi
done
for s in $(loginctl list-sessions --no-legend | awk '{ print $1 }'); do
    [ "$(loginctl show-session "$s" -p Class --value)" = user ] || continue
    [ "$(loginctl show-session "$s" -p State --value)" != closing ] || continue
    echo "reboot required, but session $s of $(loginctl show-session "$s" -p Name --value) is open"
    exit 0
done
echo "reboot required by: $(tr '\n' ' ' < /run/reboot-required.pkgs 2>/dev/null || true)- no user session, reboot now"
systemctl reboot
