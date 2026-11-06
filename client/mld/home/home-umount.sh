#!/bin/bash
# Unmounts the CIFS home of a user after the user manager stops (user@.service ExecStopPost).
#
#   mld-home-umount UID
#
# pam_mount unmounts at logout, but then the user manager (systemd --user) still runs for
# UserStopDelaySec (10 s) and keeps the home busy: "umount: target is busy". Nothing tries again later.
set -euo pipefail

uid="${1:?usage: mld-home-umount UID}"
# AD users only: sssd ID mapping gives UIDs from 200000.
[ "$uid" -ge 200000 ] || exit 0
entry=$(getent passwd "$uid") || exit 0
user=$(cut -d: -f1 <<<"$entry")
home=$(cut -d: -f6 <<<"$entry")
[ "$(findmnt -no FSTYPE --target "$home" 2>/dev/null)" = cifs ] || exit 0
[ "$(findmnt -no TARGET --target "$home")" = "$home" ] || exit 0
# pam_mount counts the open logins of the user. Another session (for example GDM) keeps the home.
count=$(cat "/run/pam_mount/$user" 2>/dev/null || echo 0)
[ $(( count )) -eq 0 ] || { echo "$user has $(( count )) pam_mount logins: home stays mounted"; exit 0; }
if pgrep -u "$uid" >/dev/null; then echo "$user has processes: home stays mounted"; exit 0; fi
# A failure here must not mark user@.service as failed: report it, the next boot cleans up.
if umount "$home"; then echo "unmounted $home"; else echo "umount $home failed"; fi
