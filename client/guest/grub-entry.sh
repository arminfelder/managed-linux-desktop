# shellcheck shell=bash
# Runs in the client as root (build.sh guest_run). Prints the number of the plain shim + grub boot entry.
efibootmgr | sed -n 's/^Boot\([0-9A-F]\{4\}\)\*\{0,1\} \(.*\)/\1 \2/p' \
    | awk '$2 != "MLD" && tolower($0) ~ /ubuntu/ { print $1; exit }'
