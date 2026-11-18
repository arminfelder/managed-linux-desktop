#!/bin/bash
# Prints the AVC lines since boot that no regex in avc-ignore.list matches. No events: no output, exit 0.
IGNORE="${AVC_IGNORE:-/etc/mld/selinux/avc-ignore.list}"
pat=$(mktemp)
trap 'rm -f "$pat"' EXIT
awk '!/^[[:space:]]*(#|$)/ { print $1 }' "$IGNORE" > "$pat" 2>/dev/null || true
# ausearch exits 1 and prints "<no matches>" on stderr when there are no events.
err=$(mktemp)
trap 'rm -f "$pat" "$err"' EXIT
# When stdin is not a terminal, ausearch reads its records from stdin. Under guest-exec (bash -s) that is the rest
# of the caller script, under systemd it is /dev/null. --input-logs reads the audit log in all cases.
if ! out=$(ausearch --input-logs -m AVC,USER_AVC -ts boot -i 2>"$err" </dev/null); then
    if [ -z "$out" ] && grep -qx '<no matches>' "$err"; then
        out=""
    else
        echo "mld-avc-report: ausearch failed: $(cat "$err")" >&2
        exit 2
    fi
fi
printf '%s\n' "$out" | grep -E '^type=(USER_)?AVC' | grep -Evf "$pat" || true
