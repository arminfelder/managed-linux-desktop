#!/usr/bin/env bash
# FreeIPA server provisioning (IDP=freeipa). Installed as /usr/local/sbin/mld-ipa-provision, started by
# mld-ipa-provision.service. State in /var/lib/mld-ipa: phase (number), DONE, FAILED, provision.log.
# The phases are idempotent: ./build.sh dc resume [N] runs them again from phase N.
set -Eeuo pipefail
STATE="${MLD_IPA_STATE:-/var/lib/mld-ipa}"
LIB="${MLD_IPA_LIB:-/usr/local/lib/mld-ipa}"
CONF="${MLD_IPA_CONF:-/etc/mld-ipa/config.env}"
PHASES=(01-install 02-directory 03-nfs 04-pki 05-policy)

mkdir -p "$STATE"
exec >>"$STATE/provision.log" 2>&1
# shellcheck source=/dev/null
. "$CONF"
n=0
log() { printf '%s phase %s: %s\n' "$(date -u +%FT%TZ)" "$n" "$*"; }
fail() { printf '%s phase %s: %s\n' "$(date -u +%FT%TZ)" "$n" "$*" > "$STATE/FAILED"; log "FAILED: $*"; exit 1; }
trap 'fail "line $LINENO: $BASH_COMMAND"' ERR

# Admin ticket for the ipa commands of the phases. A file ccache, because each ipa command is its own process.
export KRB5CCNAME="FILE:$STATE/admin.cc"
ipa_kinit() { ( umask 077; printf '%s' "$ADMIN_PW" | kinit admin >/dev/null ); }
# ipa_q ARGS...: runs ipa ARGS. An "already there" answer counts as success, so a phase can run again.
ipa_q() {
    local out
    out=$(ipa "$@" 2>&1) && return 0
    grep -qiE 'already exists|already a member|already disabled|no modifications to be performed' <<<"$out" && return 0
    printf '%s\n' "$out" >&2
    return 1
}

rm -f "$STATE/FAILED"
start=$(cat "$STATE/phase" 2>/dev/null || echo 1)
[[ "$start" =~ ^[0-9]+$ ]] || start=1
for i in "${!PHASES[@]}"; do
    n=$((i + 1))
    [ "$n" -ge "$start" ] || continue
    echo "$n" > "$STATE/phase"
    log "start ${PHASES[$i]}"
    t0=$(date +%s)
    # shellcheck source=/dev/null
    . "$LIB/${PHASES[$i]}.sh"
    log "done ${PHASES[$i]} ($(( $(date +%s) - t0 )) s)"
    printf '%s %s s\n' "${PHASES[$i]}" "$(( $(date +%s) - t0 ))" >> "$STATE/timing.log"
done
date -u +%FT%TZ > "$STATE/DONE"
log "provisioning DONE"
