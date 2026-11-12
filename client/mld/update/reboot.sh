#!/bin/bash
# Reboot after updates, at night (mld-reboot.timer). Only when a reboot is necessary and no user session is open.
set -euo pipefail
. /etc/mld/config.env || { echo "missing /etc/mld/config.env: run ./build.sh client resume" >&2; exit 1; }
. /etc/mld/distro.sh || { echo "missing /etc/mld/distro.sh: run ./build.sh client resume" >&2; exit 1; }
reboot_needed() {
    case "$CLIENT_DISTRO" in
    ubuntu) [ -e /run/reboot-required ] ;;
    # Exit 1 = reboot recommended, 0 = none. Other codes are errors: no reboot.
    fedora) local rc=0; dnf needs-restarting -r >/dev/null || rc=$?; [ "$rc" = 1 ] ;;
    esac
}
case "$CLIENT_DISTRO" in
ubuntu) BUSY_UNITS="mld-firstboot.service apt-daily-upgrade.service" ;;
fedora) BUSY_UNITS="mld-firstboot.service dnf5-automatic.service" ;;
esac
reboot_needed || exit 0
# Without TPM2 unlock, the client stops at the LUKS passphrase prompt.
if ! grep -qs 'tpm2-device=' "${CRYPTTAB:-/etc/crypttab}"; then
    echo "reboot required, but the disk has no TPM2 unlock: reboot by hand"
    exit 0
fi
for u in $BUSY_UNITS; do
    # Oneshot units are "activating" while they run: is-active is false then.
    case "$(systemctl show -p ActiveState --value "$u")" in
    activating|deactivating) echo "reboot required, but $u runs"; exit 0 ;;
    esac
done
for s in $(loginctl list-sessions --no-legend | awk '{ print $1 }'); do
    [ "$(loginctl show-session "$s" -p Class --value)" = user ] || continue
    [ "$(loginctl show-session "$s" -p State --value)" != closing ] || continue
    echo "reboot required, but session $s of $(loginctl show-session "$s" -p Name --value) is open"
    exit 0
done
if [ "$CLIENT_DISTRO" = ubuntu ]; then
    echo "reboot required by: $(tr '\n' ' ' < /run/reboot-required.pkgs 2>/dev/null || true)- no user session, reboot now"
else
    echo "reboot required by package updates - no user session, reboot now"
fi
systemctl reboot
