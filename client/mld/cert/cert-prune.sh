#!/bin/bash
# certmonger post-save command (getcert -C): after a renewal, keep only the newest certificate in the TPM token.
#
#   getcert request ... -C '/usr/local/libexec/mld-cert-prune machine|user'
#
# A wrapper with its own file type (certmonger_unconfined_exec_t, Fedora fcontexts.list), as mld-cm-submit:
# the system certmonger runs it outside its confined domain.
set -euo pipefail
case "${1:-}" in
    machine|user) exec /usr/local/sbin/mld-autoenroll prune "$1" ;;
    *) echo "usage: mld-cert-prune machine|user" >&2; exit 2 ;;
esac
