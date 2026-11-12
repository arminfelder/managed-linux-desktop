#!/bin/bash
# certmonger CA helper for AD CS. certmonger makes the key in the TPM token and the CSR; this helper only submits.
#
#   getcert add-ca -c MLD-AD -e '/usr/local/libexec/mld-cm-submit machine web'
#
# Arguments: machine|user (which Kerberos ticket) and web|dcom (certsrv or ICertRequestD).
# Protocol (certmonger submit helper): $CERTMONGER_OPERATION selects the operation, the CSR is in
# $CERTMONGER_CSR, the template in $CERTMONGER_CA_PROFILE. Exit: 0 issued (PEM on stdout), 2 rejected,
# 3 CA unreachable, 5 wait (delay on stdout), 6 operation not supported.
set -uo pipefail

who="${1:-machine}" how="${2:-web}"

case "${CERTMONGER_OPERATION:-SUBMIT}" in
    IDENTIFY)
        echo "mld-cm-submit ($who, $how)"; exit 0 ;;
    GET-NEW-REQUEST-REQUIREMENTS|GET-RENEW-REQUEST-REQUIREMENTS)
        echo "CERTMONGER_CA_PROFILE"; exit 0 ;;
    FETCH-ROOTS)
        # All CA certificates from AD (mld-cert ca): a nickname line, then the PEM, for each one.
        # shellcheck source=/dev/null
        . /etc/mld-cert.conf
        CLIENT_DISTRO=${CLIENT_DISTRO:-ubuntu}
        if [ -z "${CA_ANCHOR_DIR:-}" ]; then
            [ "$CLIENT_DISTRO" = ubuntu ] || { echo "CA_ANCHOR_DIR missing in /etc/mld-cert.conf: run ./build.sh client resume" >&2; exit 3; }
            CA_ANCHOR_DIR=/usr/local/share/ca-certificates/mld CA_ANCHOR_PREFIX=
        fi
        n=0
        for f in "$CA_ANCHOR_DIR"/${CA_ANCHOR_PREFIX:-}*.crt; do
            [ -s "$f" ] || continue
            n=$((n + 1)); if [ "$n" = 1 ]; then echo "$CA_NAME"; else echo "$CA_NAME $n"; fi; cat "$f"
        done
        [ "$n" -gt 0 ] || exit 3
        exit 0 ;;
    SUBMIT|POLL)
        [ -n "${CERTMONGER_CSR:-}" ] || { echo "no CSR" >&2; exit 4; }
        [ -n "${CERTMONGER_CA_PROFILE:-}" ] || { echo "no template (getcert -T)" >&2; exit 4; }
        tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
        printf '%s\n' "$CERTMONGER_CSR" > "$tmp/req.pem"
        /usr/local/sbin/mld-cert submit "$who" "$how" "$CERTMONGER_CA_PROFILE" "$tmp/req.pem" "$tmp/cert.pem" >&2
        rc=$?
        case "$rc" in
            0) cat "$tmp/cert.pem"; exit 0 ;;
            5) echo 3600; exit 5 ;;
            3) exit 3 ;;
            *) exit 2 ;;
        esac ;;
    *)
        exit 6 ;;
esac
