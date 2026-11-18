#!/usr/bin/env bash
# ============================================================================
# Reproducible lab for a managed Linux client in an AD environment.
# DC: Windows Server 2025 (AD DS, DNS, Homes$ share). Client: Ubuntu 26.04 with
# Secure Boot, LUKS2 (passphrase, optional TPM2 and FIDO2), AD join, CIFS home.
#
#   ./build.sh config             ask for the settings that lab.env does not have, then show all settings
#   ./build.sh check              host tools, libvirt network/pool, media checksums
#   ./build.sh fetch              download missing media, then verify checksums
#   ./build.sh pin                record checksums of media that have none (trust on first use)
#   ./build.sh net                define libvirt network + pool if they are missing
#
#   ./build.sh dc iso             render config and build .stage/dc-provision.iso
#   ./build.sh dc vm              create and boot the DC (unattended)
#   ./build.sh dc start           start a shut-off DC
#   ./build.sh dc wait            block until DC provisioning is DONE or FAILED
#   ./build.sh dc phase|log [N]|resume [PHASE]|verify|screenshot
#   ./build.sh dc set-passwords   set the AD passwords on the DC to the values in lab.env (not DSRM)
#   ./build.sh dc policy          IDP=freeipa: publish ipa/policy/*.json again (the clients pull it, mld-policy)
#   ./build.sh dc snapshot|revert|destroy [--confirm NAME]
#
#   ./build.sh client iso         remaster the Ubuntu ISO, build .stage/cidata.iso (with the offline join blob)
#   ./build.sh client hw-iso      install image for real hardware: .stage/mld-hw.iso (no passwords, the blobs in /odj)
#   ./build.sh client odj [--replace] NAME..  offline join blobs from the DC: .stage/odj/NAME.txt (no join password);
#                                 --replace deletes an existing computer account of that name in the Linux OU first
#   ./build.sh client vm          install the client, then boot and unlock it
#   ./build.sh client start       boot a shut-off client and type the passphrase
#   ./build.sh client unlock      type the passphrase at a prompt that is open now
#   ./build.sh client autoenroll-test [web|dcom]  certmonger autoenrollment from AD: machine + probe user (TPM tokens)
#   ./build.sh client pki-test    machine + user certificate (TPM key) via certsrv web and via DCOM
#   ./build.sh client resume      push firstboot.sh, start first boot again (after a FAILED phase)
#   ./build.sh client wait        block until first-boot provisioning is DONE or FAILED
#   ./build.sh client verify      Secure Boot, LUKS2, keyslots, AD, login + CIFS end to end
#   ./build.sh client reboot-test reboot and require unlock without a passphrase (TPM2/FIDO2)
#   ./build.sh client mok-enroll  UKI_TRUST=mok: MOK request, MokManager on the serial console, shim UKI entry, TPM2
#   ./build.sh client fallback-test  boot shim + grub once: TPM2 must refuse, the passphrase must unlock
#   ./build.sh client fido2-attach  pass the FIDO2_HOSTDEV key into the VM
#   ./build.sh client enroll-fido2  enroll the passed-through key (touch the key)
#   ./build.sh client log [N]|screenshot|snapshot|revert|destroy [--confirm NAME]
#   ./build.sh client installer-diag ['CMD' ...]  type commands in the installer shell (VT2), screenshot
#   ./build.sh client type 'TEXT'  type TEXT + Enter on the active console (installer shell, no agent)
#
#   ./build.sh setup              everything in one command: media, pin, network, check, DC, client, tests, snapshots
#   ./build.sh all                check, dc, client, verify, snapshots (the media and the network must be there)
#   (setup and all continue after an interruption: a VM with the post-build snapshot is skipped)
#
# Each command first asks for the settings that lab.env does not have (env.example has the list and the
# defaults) and writes the answers to lab.env. Without a terminal it takes the defaults and generates passwords.
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

usage() { awk 'NR > 2 && /^# ====/ { exit } NR > 2 { sub(/^# ?/, ""); print }' "$0"; }
case "${1:-}" in ''|-h|--help|help) usage; exit 0 ;; esac

# The settings were in .env before. The new name is outside the "./.env" read rules of the Claude sandbox.
if [ -f .env ] && [ ! -e lab.env ]; then mv .env lab.env; echo "[build] .env renamed to lab.env" >&2; fi

# shellcheck source=lib/settings.sh
. "$HERE/lib/settings.sh"
settings_complete
set -a; . ./lab.env; set +a

STAGE="$HERE/.stage"
OVMF_CODE="${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE_4M.secboot.fd}"
OVMF_VARS="${OVMF_VARS:-/usr/share/OVMF/OVMF_VARS_4M.ms.fd}"
SNAPSHOT="${SNAPSHOT:-post-build}"
GUEST_WORK='C:\build'

# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"
# shellcheck source=lib/config.sh
. "$HERE/lib/config.sh"
# shellcheck source=lib/host.sh
. "$HERE/lib/host.sh"
if [ "$IDP" = freeipa ]; then
    # shellcheck source=lib/ipa.sh
    . "$HERE/lib/ipa.sh"
else
    # shellcheck source=lib/dc.sh
    . "$HERE/lib/dc.sh"
fi
# shellcheck source=lib/client.sh
. "$HERE/lib/client.sh"
# shellcheck source=lib/tests.sh
. "$HERE/lib/tests.sh"

cmd_client() {
    local sub="${1:-}"; shift || true
    case "$sub" in
        iso) client_iso ;;
        hw-iso) client_hw_iso ;;
        odj) local rep=0 n; [ "${1:-}" != --replace ] || { rep=1; shift; }
             [ $# -ge 1 ] || die "usage: client odj [--replace] NAME [NAME ...]"
             for n in "$@"; do REPLACE=$rep odj_provision "$n"; done ;;
        vm) client_vm ;;
        start) client_start ;;
        unlock) client_unlock ;;
        wait) client_wait ;;
        resume) client_resume ;;
        pki-test) client_pki_test ;;
        autoenroll-test) client_autoenroll_test "$@" ;;
        set-admin-password) client_set_admin_password ;;
        nvram-qcow2) client_nvram_qcow2 ;;
        log) client_log "$@" ;;
        verify) client_verify ;;
        reboot-test) client_reboot_test ;;
        mok-enroll) client_mok_enroll ;;
        fallback-test) client_fallback_test ;;
        fido2-attach) client_fido2_attach ;;
        enroll-fido2) client_enroll_fido2 ;;
        screenshot) screenshot_vm "$CLIENT_VM" "${1:-$STAGE/client-console.png}" ;;
        installer-diag)
              # Types commands into the installer shell on VT2, then takes a screenshot.
              # Default: what downloads, what runs.
              local u="$LIBVIRT_URI" k="$HERE/lib/sendkeys.py" c
              [ $# -gt 0 ] || set -- "clear" "sudo ss -tnp | grep -v 127.0 | cut -c50-200 | head -6" \
                  "ps -eo etime,args --sort=-pcpu | head -6 | cut -c1-150" "ls /var/log/installer"
              "${VIRSH[@]}" send-key "$CLIENT_VM" KEY_LEFTCTRL KEY_LEFTALT KEY_F2 >/dev/null
              sleep 1
              # A Shift tap releases a Shift that an earlier send-key left pressed.
              "${VIRSH[@]}" send-key "$CLIENT_VM" KEY_LEFTSHIFT >/dev/null
              "${VIRSH[@]}" send-key "$CLIENT_VM" KEY_RIGHTSHIFT >/dev/null
              "${VIRSH[@]}" send-key "$CLIENT_VM" KEY_LEFTCTRL KEY_C >/dev/null; sleep 1
              for c in "$@"; do python3 "$k" "$u" "$CLIENT_VM" "$c"; sleep 2; done
              screenshot_vm "$CLIENT_VM" "$STAGE/client-console.png" ;;
        type) [ $# -ge 1 ] || die "usage: client type 'TEXT' (typed on the active console, then Enter)"
              python3 "$HERE/lib/sendkeys.py" "$LIBVIRT_URI" "$CLIENT_VM" "$*" ;;
        snapshot) snapshot_vm "$CLIENT_VM" "$SNAPSHOT" ;;
        revert) "${VIRSH[@]}" snapshot-revert "$CLIENT_VM" "$SNAPSHOT" --running ;;
        destroy) destroy_vm "$CLIENT_VM" "$@" ;;
        *) die "unknown: client ${sub:-<nothing>} (try ./build.sh help)" ;;
    esac
}

snapshot_exists() { "${VIRSH[@]}" snapshot-info "$1" "$2" >/dev/null 2>&1; }
vm_running() { [ "$("${VIRSH[@]}" domstate "$1" 2>/dev/null)" = running ]; }

# Each stage continues where an earlier run stopped: a VM with the snapshot is done, a VM without it is waited for.
dc_stage() {
    if snapshot_exists "$DC_VM" "$SNAPSHOT"; then log "DC: snapshot $SNAPSHOT exists, build skipped"; return; fi
    if vm_exists "$DC_VM"; then
        log "DC: VM exists, waiting for its provisioning"
        vm_running "$DC_VM" || dc_start
    else dc_iso; dc_vm; fi
    dc_wait; dc_verify; snapshot_vm "$DC_VM" "$SNAPSHOT"
}

client_stage() {
    if snapshot_exists "$CLIENT_VM" "$SNAPSHOT"; then log "client: snapshot $SNAPSHOT exists, build skipped"; return; fi
    if vm_exists "$CLIENT_VM"; then
        log "client: VM exists, waiting for its first boot"
        vm_running "$CLIENT_VM" || client_start
    else client_iso; client_vm; fi
    client_wait
    if [ "${UKI:-0}" = 1 ] && [ "$UKI_TRUST" = mok ]; then client_mok_enroll; fi
    client_verify
    if [ "${ENROLL_TPM2:-0}" = 1 ]; then client_reboot_test; fi
    if [ "${UKI:-0}" = 1 ] && [ "${ENROLL_TPM2:-0}" = 1 ]; then client_fallback_test; fi
    if [ "${PKI_ENROLL:-none}" != none ]; then client_autoenroll_test; fi
    snapshot_vm "$CLIENT_VM" "$SNAPSHOT"
}

cmd_all() {
    cmd_check
    dc_stage
    client_stage
}

# One command from an empty checkout to a tested lab. A second run continues after an interruption.
cmd_setup() {
    local t0=$SECONDS
    log "1/4 media: download, then check the sums"
    fetch_server_media
    fetch_client_media
    # Microsoft and virtio-win publish no sums: the first download is pinned (trust on first use).
    # A file with a pinned sum that does not match stops the setup.
    local before; before=$(cat "$HERE/checksums.sha256" 2>/dev/null)
    pin_media
    [ "$before" = "$(cat "$HERE/checksums.sha256" 2>/dev/null)" ] \
        || warn "new sums in checksums.sha256: commit the file"
    verify_media || die "media not verified: do not use these files"
    log "2/4 libvirt network and pool"
    cmd_net
    log "3/4 host check"
    cmd_check
    log "4/4 DC, then client (about 1.5 to 2.5 hours for a new lab)"
    dc_stage
    client_stage
    log "lab ready after $(( (SECONDS - t0) / 60 )) min"
    [ ! -f "$STAGE/recovery-key" ] || warn "the LUKS recovery key is in $STAGE/recovery-key: keep it in a safe location"
    log "Next: open $CLIENT_VM in virt-manager and log in as ${PROBE_USER:-alice} (password LAB_USER_PW in lab.env)"
}

# ---------------------------------------------------------------------------
case "${1:-}" in
    config) settings_show ;;
    check|fetch|pin|net|all|setup) c="$1"; shift; "cmd_$c" "$@" ;;
    dc|client) c="$1"; shift; "cmd_$c" "$@" ;;
    *) die "unknown command '$1' (try ./build.sh help)" ;;
esac
