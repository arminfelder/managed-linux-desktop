#!/bin/bash
# Runs as the user (systemd user unit mld-desktop.service). AD users only (UID from 200000, sssd ID mapping).
# The CIFS home has file_mode=0600 and ignores chmod, so a launcher there cannot be executable.
# The desktop starts a launcher only if it is executable (GNOME: also metadata::trusted). Thus the desktop folder is local.
set -euo pipefail
uid=$(id -u)
[ "$uid" -ge 200000 ] || exit 0
# pam_mount can mount the home after the user manager starts.
for _ in $(seq 1 30); do [ -w "$HOME" ] && break; sleep 1; done
[ -w "$HOME" ] || { echo "home $HOME is not writable"; exit 1; }

state=/var/lib/mld-users/$uid
desk=$state/Desktop
[ -d "$state" ] || install -d -m 700 "$state"
[ "$(stat -c %u "$state")" = "$uid" ] || { echo "$state is not owned by $uid"; exit 1; }
install -d -m 700 "$desk"
[ "$(xdg-user-dir DESKTOP)" = "$desk" ] || xdg-user-dirs-update --set DESKTOP "$desk"

# The launchers that this script manages (patterns). snx-rs-gui.desktop comes from the snx-rs package (SNX_RS=1).
managed=('mld-o365-*.desktop' 'snx-rs-gui.desktop')
for p in "${managed[@]}"; do
    for f in "$desk"/$p; do
        if [ -e "$f" ] && [ ! -e "/usr/share/applications/${f##*/}" ]; then rm -f "$f"; fi
    done
    for f in /usr/share/applications/$p; do
        [ -e "$f" ] || continue
        t="$desk/${f##*/}"
        cmp -s "$f" "$t" || install -m 755 "$f" "$t"
        # GNOME (Desktop Icons NG) needs metadata::trusted, kept by gvfsd-metadata. KDE has no gvfs: 755 is enough.
        if [ -x /usr/libexec/gvfsd-metadata ]; then gio set "$t" metadata::trusted true; fi
    done
done
