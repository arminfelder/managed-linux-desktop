# shellcheck shell=bash
# Runs in the client as root (build.sh guest_run). First-boot state as JSON for build.sh client wait.
s=/var/lib/mld
# shellcheck disable=SC1003 # '"\\' is the tr set: double quote and backslash.
read_marker() { cat "$s/$1" 2>/dev/null | tr -d '"\\'; }
printf '{"phase":"%s","done":"%s","failed":"%s"}\n' "$(read_marker phase)" "$(read_marker DONE)" "$(read_marker FAILED)"
