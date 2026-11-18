# shellcheck shell=bash
# Runs in the client as root (build.sh guest_run). Prints the number of the plain shim + grub boot entry.
. /etc/mld/config.env || { echo "missing /etc/mld/config.env: run ./build.sh client resume" >&2; exit 1; }
. /etc/mld/distro.sh || { echo "missing /etc/mld/distro.sh: run ./build.sh client resume" >&2; exit 1; }
efibootmgr | sed -n 's/^Boot\([0-9A-F]\{4\}\)\*\{0,1\} \(.*\)/\1 \2/p' \
    | awk -v re="$BOOT_LABEL_RE" '$2 != "MLD" && tolower($0) ~ re { print $1; exit }'
