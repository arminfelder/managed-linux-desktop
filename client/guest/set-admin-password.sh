# shellcheck shell=bash
# Runs in the client as root (build.sh guest_run). Needs ADMIN_USER, ADMIN_PW.
id "$ADMIN_USER" >/dev/null
printf '%s:%s\n' "$ADMIN_USER" "$ADMIN_PW" | chpasswd
passwd -S "$ADMIN_USER"
