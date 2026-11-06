# shellcheck shell=bash
# Runs in the client as root (build.sh guest_run). Needs SUB (mld-firstboot arguments), PASSWORD, PIN, TAIL.
export PASSWORD PIN
# shellcheck disable=SC2086 # SUB is a word list.
/usr/local/sbin/mld-firstboot $SUB; rc=$?
tail -n "$TAIL" /var/log/mld-firstboot.log
exit "$rc"
