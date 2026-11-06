#!/bin/bash
# First-boot provisioning of the lab client. Runs once as mld-firstboot.service, as root.
# Input: /etc/mld (copied from the CIDATA CD by the autoinstall late-commands).
# Markers for the host: /var/lib/mld/DONE, /var/lib/mld/FAILED. Log: /var/log/mld-firstboot.log.
#
#   mld-firstboot                                   all phases (done phases are skipped through markers)
#   PASSWORD=<passphrase> mld-firstboot enroll-tpm2  seal a TPM2 keyslot now (replaces an old one)
#   PASSWORD=<passphrase> [PIN=<pin>] mld-firstboot enroll-fido2 yes|no   (yes = require the client PIN)
#   mld-firstboot join FILE                         offline domain join blob of this computer, then all phases
#   mld-firstboot secure                            real hardware: recovery key, MOK request, TPM2 (asks on the screen)
#
# -E: the ERR trap must also apply in functions, else a failed phase writes no FAILED marker.
set -Eeuo pipefail

CFG=/etc/mld
STATE=/var/lib/mld
mkdir -p "$STATE"
chmod 700 "$STATE"
# The interactive subcommands show their output on the screen too.
case "${1:-}" in
    secure|join) exec > >(tee -a /var/log/mld-firstboot.log) 2>&1 ;;
    *) exec >>/var/log/mld-firstboot.log 2>&1 ;;
esac
# shellcheck source=/dev/null
. "$CFG/config.env"

# "enroll-fido2" and "enroll-tpm2" run later from build.sh. Their errors must not set the first-boot FAILED marker.
MARKER="$STATE/FAILED"
case "${1:-}" in enroll-fido2|enroll-tpm2|secure|join) MARKER=/dev/null ;; esac

phase() { echo "$1" > "$STATE/phase"; echo "=== $(date -u +%FT%TZ) phase $1 ==="; }
fail() {
    trap - ERR
    echo "phase $(cat "$STATE/phase" 2>/dev/null || true): $*" > "$MARKER"
    echo "FAILED: $*"
    exit 1
}
trap 'fail "line $LINENO: $BASH_COMMAND"' ERR

# Installs the packages that are not installed yet, in one apt-get call.
pkg_install() {
    local p missing=()
    for p in "$@"; do dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p"); done
    if [ "${#missing[@]}" -gt 0 ]; then DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"; fi
}

# One file per topic: client/mld/<topic>/phase.sh, in /etc/mld/<topic>/ on the client.
for topic in boot ad cert home apps desktop gpo vpn update brand; do
    # shellcheck source=/dev/null
    . "$CFG/$topic/phase.sh"
done

phase_cleanup() {
    phase cleanup
    # The LUKS passphrase stays as a keyslot. The copy in /etc/mld is not necessary after enrollment.
    # A second run (client resume) finds the files shredded already.
    local f
    for f in "$CFG/join-pass" "$CFG/odj.txt" "$CFG/luks-pass" "$CFG/admin-hash"; do [ ! -e "$f" ] || shred -u "$f"; done
    # Older versions had all files flat in /etc/mld. A flat file with the name of a topic file is an old copy.
    for f in "$CFG"/*/*; do
        if [ -f "$f" ] && [ -f "$CFG/${f##*/}" ]; then rm -f "$CFG/${f##*/}"; fi
    done
}

main() {
    rm -f "$STATE/FAILED"
    phase_admin_pw
    if [ "${CLIENT_TARGET:-vm}" = hw ]; then phase_luks_check; fi
    # The lab VMs get the LUKS passphrase on CIDATA. Real hardware has none: mld-firstboot secure asks for it.
    if [ -s "$CFG/luks-pass" ]; then
        [ -f "$STATE/recovery.done" ] || phase_recovery_key
        if [ "${ENROLL_TPM2:-0}" = 1 ] && [ ! -f "$STATE/tpm2.done" ]; then phase_tpm2; fi
    fi
    phase_dns
    phase_updates
    # Clients from before the offline join were joined with realm join: realm list shows them.
    [ -f "$STATE/join.done" ] || realm list --name-only | grep -qx "$DOMAIN" || phase_join
    phase_sssd
    [ "${PKI_ENROLL:-none}" = none ] || phase_pki
    phase_pam
    if [ "${UKI:-0}" = 1 ]; then phase_uki; fi
    phase_browsers
    phase_desktop
    phase_brand
    phase_gpo
    if [ "${SNX_RS:-1}" = 1 ]; then phase_snx; else phase_snx_remove; fi
    phase_cleanup
    # The lab VMs: build.sh does these steps from the host (client mok-enroll).
    if [ "${CLIENT_TARGET:-vm}" = hw ]; then secure_motd; fi
    trap - ERR
    date -u +%FT%TZ > "$STATE/DONE"
    echo "=== DONE ==="
}

# Steps of mld-firstboot secure that are still open (real hardware). Empty = nothing to do.
secure_open() {
    local open=""
    [ -f "$STATE/recovery.done" ] || open+=" recovery-key"
    if [ "${UKI:-0}" = 1 ] && [ "${UKI_TRUST:-db}" = mok ]; then
        [ "$(/usr/local/sbin/mld-uki mok-state)" = enrolled ] || open+=" mok"
        uki_booted || open+=" uki-boot"
    fi
    if [ "${ENROLL_TPM2:-0}" = 1 ] && [ ! -f "$STATE/tpm2.done" ]; then open+=" tpm2"; fi
    echo "${open# }"
}

# The login message names the open steps, so that the administrator sees them.
secure_motd() {
    local open; open=$(secure_open)
    if [ -z "$open" ]; then rm -f /etc/motd; return 0; fi
    printf '%s\n' '' "MLD: this device is not secured completely (open: $open)." \
        "Run: sudo mld-firstboot secure" '' > /etc/motd
}

# Real hardware: the steps that need the LUKS passphrase or a person at the console. Each run does what is possible
# now and tells what comes next. Run it again after each reboot until it reports no open steps.
cmd_secure() {
    local open dev pw state
    open=$(secure_open)
    if [ -z "$open" ]; then echo "Nothing to do: recovery key, MOK and TPM2 are done."; secure_motd; return 0; fi
    echo "Open steps: $open"
    dev=$(luks_dev)
    if [[ " $open " == *" recovery-key "* || " $open " == *" tpm2 "* ]]; then
        read -rsp "LUKS passphrase of this disk: " pw </dev/tty; echo
        printf '%s' "$pw" | cryptsetup open --test-passphrase "$dev" --key-file=- || { echo "wrong passphrase"; exit 1; }
    fi
    if [[ " $open " == *" recovery-key "* ]]; then
        echo "Recovery key (write it down now, keep it in a safe place; it is not stored on this device):"
        PASSWORD=$pw systemd-cryptenroll --recovery-key "$dev"
        touch "$STATE/recovery.done"
    fi
    if [[ " $open " == *" mok "* ]]; then
        /usr/local/sbin/mld-uki keygen
        /usr/local/sbin/mld-uki sync
        state=$(/usr/local/sbin/mld-uki mok-state)
        [ "$state" = pending ] || /usr/local/sbin/mld-uki mok-request
        echo "Next: reboot. In the blue MokManager screen select Enroll MOK, Continue, Yes, type the MOK password, Reboot."
        echo "Then run: sudo mld-firstboot secure"
        secure_motd; return 0
    fi
    if [[ " $open " == *" uki-boot "* ]]; then
        /usr/local/sbin/mld-uki sync
        echo "Next: reboot (the boot entry MLD UKI (shim) is first now). Then run: sudo mld-firstboot secure"
        secure_motd; return 0
    fi
    if [[ " $open " == *" tpm2 "* ]]; then
        PASSWORD=$pw enroll_tpm2
        echo "TPM2 sealed to PCR ${TPM2_PCRS:-7}. The next boots unlock the disk without the passphrase."
    fi
    secure_motd
    echo "Open steps now: $(secure_open || true)"
}

# A device without a blob from the install: copy the blob (djoin /provision on the DC), then join and continue.
cmd_join() {
    [ -s "${1:-}" ] || { echo "usage: mld-firstboot join FILE (offline domain join blob of this computer)" >&2; exit 2; }
    install -m 600 "$1" "$CFG/odj.txt"
    rm -f "$STATE/FAILED"
    systemctl restart --no-block mld-firstboot.service
    echo "first boot started again with the blob. Progress: journalctl -fu mld-firstboot"
}

case "${1:-}" in
    join) cmd_join "${2:-}" ;;
    secure) cmd_secure ;;
    enroll-tpm2) cmd_enroll_tpm2 ;;
    enroll-fido2) cmd_enroll_fido2 "${2:-no}" ;;
    *) main ;;
esac
