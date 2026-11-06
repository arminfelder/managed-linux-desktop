# shellcheck shell=sh
# The home of an AD user is on CIFS. Caches and lock files work badly on CIFS, so keep them local.
# AD users only: sssd ID mapping gives UIDs from 200000. systemd dynamic users are below that.
if [ "$(id -u)" -ge 200000 ]; then
    XDG_CACHE_HOME="/var/tmp/xdg-cache/$(id -un)"
    mkdir -p "$XDG_CACHE_HOME" && chmod 700 "$XDG_CACHE_HOME"
    export XDG_CACHE_HOME
fi
