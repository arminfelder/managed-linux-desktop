# shellcheck shell=bash
# LUKS keyslots (recovery key, TPM2, FIDO2), initrd, UKI.
# Sourced by mld-firstboot (client/mld/firstboot.sh): phase, fail, CFG, STATE and the config.env values are set.

# The first non-comment line of /etc/crypttab is the root PV made by the installer.
crypttab_field() { awk -v f="$1" '!/^[[:space:]]*#/ && NF { print $f; exit }' /etc/crypttab; }
luks_name() { crypttab_field 1; }
luks_dev() {
    local src; src=$(crypttab_field 2)
    case "$src" in UUID=*) blkid -U "${src#UUID=}" ;; *) echo "$src" ;; esac
}

# Adds OPT to the options field of the root line in /etc/crypttab if it is not there.
crypttab_add() {
    local opt="$1" name; name=$(luks_name)
    awk -v n="$name" -v o="$opt" '
        $1 == n && $0 !~ ("(^|[ ,\t])" o "([,\t ]|$)") {
            if (NF < 4) { $3 = ($3 == "" ? "none" : $3); $4 = o } else { $4 = $4 "," o }
        } { print }' OFS='\t' /etc/crypttab > /etc/crypttab.new
    mv /etc/crypttab.new /etc/crypttab
}

# dracut does not always copy /etc/crypttab into a generic initrd. The tokens need the options in the initrd.
# The root disk is local, so the initrd needs no network. The network modules leave a networkd config in /run.
write_dracut_conf() {
    local mods="" m list
    # One call: with pipefail, "dracut | grep -q" fails when grep closes the pipe early (SIGPIPE).
    list=$(dracut --list-modules 2>/dev/null || true)
    for m in tpm2-tss fido2 systemd-cryptsetup; do
        grep -qx "$m" <<<"$list" && mods+=" $m"
    done
    # dyn-netconf (Ubuntu) needs systemd-networkd.
    printf 'add_dracutmodules+="%s "\ninstall_items+=" /etc/crypttab "\n%s\n' "$mods" \
        'omit_dracutmodules+=" systemd-networkd network network-legacy network-manager dyn-netconf "' \
        > /etc/dracut.conf.d/90-mld-crypt.conf
    echo "dracut modules:$mods"
}

# regen_initrd OPT: rebuilds all initrds (and the UKI) and checks that crypttab in the initrd has OPT.
regen_initrd() {
    write_dracut_conf
    dracut --force --regenerate-all
    local img; img=$(initrd_path "$(uname -r)")
    lsinitrd -f etc/crypttab "$img" | grep -q -- "$1" \
        || fail "initrd $img has no '$1' in etc/crypttab"
    # With UKI=1 the firmware boots the initrd inside the UKI. The UKI uses the same dracut configuration.
    if [ "${UKI:-0}" = 1 ]; then /usr/local/sbin/mld-uki all || fail "UKI rebuild failed"; fi
}

# With UKI=1, PCR 7 must come from the UKI boot path. A seal from the shim + grub path also opens on that path.
uki_booted() { [ -e /sys/firmware/efi/efivars/StubInfo-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f ]; }

# Needs PASSWORD. A second run replaces the TPM2 keyslot, for example after a db or dbx update.
enroll_tpm2() {
    local dev; dev=$(luks_dev)
    systemd-cryptenroll --tpm2-device=list
    systemd-cryptenroll --wipe-slot=tpm2 --tpm2-device=auto --tpm2-pcrs="$TPM2_PCRS" "$dev"
    crypttab_add tpm2-device=auto
    regen_initrd tpm2-device=auto
    touch "$STATE/tpm2.done"
}

cmd_enroll_tpm2() {
    echo "=== $(date -u +%FT%TZ) enroll-tpm2 ==="
    [ -n "${PASSWORD:-}" ] || fail "PASSWORD is empty"
    [ "${UKI:-0}" != 1 ] || uki_booted || fail "UKI=1, but this boot did not come from the UKI"
    export PASSWORD
    enroll_tpm2
    echo "=== TPM2 enrolled ==="
}

cmd_enroll_fido2() {
    local pin_flag="${1:-no}" dev
    echo "=== $(date -u +%FT%TZ) enroll-fido2 ==="
    [ -n "${PASSWORD:-}" ] || fail "PASSWORD is empty"
    dev=$(luks_dev)
    systemd-cryptenroll --fido2-device=list
    systemd-cryptenroll --fido2-device=auto --fido2-with-client-pin="$pin_flag" \
        --fido2-with-user-presence=yes "$dev"
    crypttab_add fido2-device=auto
    regen_initrd fido2-device=auto
    echo "=== FIDO2 enrolled ==="
}

# cloud-init on the installed system gets the admin user from the installer with "lock_passwd: false" and no hash.
# At the first boot its users_groups module unlocks the existing user with passwd -u and then passwd -d: the
# password is empty, and with pam_unix nullok the console login (and sudo) works without a password.
# The hash from lab.env (CLIENT_ADMIN_PW) comes in admin-hash; chpasswd -e keeps it off the command line.
phase_admin_pw() {
    local u=${CLIENT_ADMIN:-labadmin} f="$CFG/admin-hash"
    if [ "$CLIENT_DISTRO" = fedora ]; then
        case "$(passwd -S "$u" | awk '{ print $2 }')" in
            P|PS) return 0 ;;
            *) fail "$u has no password" ;;
        esac
    fi
    [ "$(passwd -S "$u" | awk '{ print $2 }')" = NP ] || return 0
    phase admin-pw
    [ -s "$f" ] || fail "$u has no password, and $f is missing (build.sh client resume pushes it)"
    printf '%s:%s\n' "$u" "$(tr -d '\n' < "$f")" | chpasswd -e
    [ "$(passwd -S "$u" | awk '{ print $2 }')" = P ] || fail "the password of $u is still not set"
    echo "password of $u set from CLIENT_ADMIN_PW (cloud-init had deleted it)"
}

# Real hardware: the person at the installer selects the encryption. Stop when root is not on LUKS2.
phase_luks_check() {
    phase luks-check
    local dev; dev=$(luks_dev 2>/dev/null || true)
    [ -n "$dev" ] \
        || fail "root is not on LUKS (no /etc/crypttab entry): install again with \"Encrypt the LVM group with LUKS\""
    [ "$(cryptsetup luksDump "$dev" | awk '/^Version:/ { print $2 }')" = 2 ] || fail "$dev is not LUKS2"
}

phase_recovery_key() {
    phase recovery-key
    local dev; dev=$(luks_dev)
    [ "$(cryptsetup luksDump "$dev" | awk '/^Version:/ { print $2 }')" = 2 ] || fail "$dev is not LUKS2"
    # The subshell keeps umask 077 away from the later phases (systemd-resolved must read its drop-in).
    ( umask 077; PASSWORD=$(cat "$CFG/luks-pass") systemd-cryptenroll --recovery-key "$dev" > "$STATE/recovery-key" )
    touch "$STATE/recovery.done"
}

phase_tpm2() {
    phase tpm2
    if [ "${UKI:-0}" = 1 ] && ! uki_booted; then
        # UKI_TRUST=mok: the first boot uses shim + grub. build.sh client mok-enroll enrolls TPM2 later.
        echo "TPM2 enrollment deferred: this boot did not come from the UKI"
    else
        PASSWORD=$(cat "$CFG/luks-pass") enroll_tpm2
    fi
}

# One UKI and one boot entry per kernel. Builds only the missing UKIs (a client from the time of the single mld.efi).
phase_uki() {
    phase uki
    /usr/local/sbin/mld-uki sync || fail "UKI sync failed"
}
