# shellcheck shell=bash
# Runs in the client as root (build.sh guest_run). Prints the ID line of /etc/os-release.
. /etc/os-release
echo "ID=$ID"
