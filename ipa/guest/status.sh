# shellcheck shell=bash
# Runs on the IPA server as root (build.sh guest_run). Provisioning state as JSON for build.sh dc wait.
s=/var/lib/mld-ipa
# shellcheck disable=SC1003 # '"\\' is the tr set: double quote and backslash.
read_marker() { cat "$s/$1" 2>/dev/null | tr -d '"\\\n'; }
printf '{"phase":"%s","done":"%s","failed":"%s","utc":%s}\n' "$(read_marker phase)" "$(read_marker DONE)" \
    "$(read_marker FAILED)" "$(date -u +%s)"
