# shellcheck shell=bash
# Login: PAM with the CIFS home (pam_mount) or a local home, sshd.
# Sourced by mld-firstboot (client/mld/firstboot.sh): phase, fail, CFG, STATE and the config.env values are set.
# The awk programs of pam_enable_mount have long lines. A comment in a quoted awk program would change the program.
# lint: disable-file=line-length

# Fedora: pam_mount goes into a custom authselect profile based on sssd. authselect has no pam_mount feature.
# auth: before the pam_usertype guard of pam_sss. pam_sss is sufficient, so a line after it never runs for AD users,
# and a line directly before pam_sss is skipped by the default=1 jump of the guard.
# session: before pam_systemd, as pam-auth-update does on Ubuntu. Else user@.service starts on the empty mountpoint.
# A line is added only when the file has no pam_mount.so yet.
pam_enable_mount() {
    case "$CLIENT_DISTRO" in
    ubuntu)
        pam-auth-update --package --enable sss libpam-mount
        [ ! -f /usr/share/pam-configs/mkhomedir ] || pam-auth-update --package --disable mkhomedir
        ;;
    fedora)
        local dir="${AUTHSELECT_DIR:-/etc/authselect}/custom/mld" f
        [ -d "$dir" ] || authselect create-profile mld -b sssd
        for f in system-auth password-auth; do
            grep -q pam_mount.so "$dir/$f" && continue
            awk '/^auth[ \t]+\[default=1 ignore=ignore success=ok\][ \t]+pam_usertype\.so isregular[ \t]*$/ { g = 1; next } g { if ($0 ~ /^auth[ \t]+sufficient[ \t]+pam_sss\.so/) f = 1; g = 0 } END { exit f ? 0 : 1 }' "$dir/$f" \
                || fail "$dir/$f has no pam_usertype guard line before the pam_sss auth line"
            grep -qE '^-session[[:space:]]+optional[[:space:]]+pam_systemd\.so' "$dir/$f" \
                || fail "$dir/$f has no pam_systemd session line"
            awk 'function flush() { if (h != "") print h; h = "" }
                /^auth[ \t]+\[default=1 ignore=ignore success=ok\][ \t]+pam_usertype\.so isregular[ \t]*$/ { flush(); h = $0; next }
                h != "" { if ($0 ~ /^auth[ \t]+sufficient[ \t]+pam_sss\.so/) print "auth        optional                                     pam_mount.so"; flush() }
                /^-session[ \t]+optional[ \t]+pam_systemd\.so/ && !s { print "session     optional                                     pam_mount.so"; s = 1 }
                { print }
                END { flush() }' "$dir/$f" > "$dir/$f.new"
            mv "$dir/$f.new" "$dir/$f"
        done
        authselect select custom/mld --force
        ;;
    esac
}

pam_disable_mount() {
    case "$CLIENT_DISTRO" in
    ubuntu) pam-auth-update --package --disable libpam-mount ;;
    fedora) authselect select sssd --force ;;
    esac
}

pam_enable_mkhomedir() {
    case "$CLIENT_DISTRO" in
    ubuntu) pam-auth-update --package --enable sss mkhomedir ;;
    fedora)
        pkg_install oddjob-mkhomedir
        authselect select sssd with-mkhomedir --force
        systemctl enable --now oddjobd.service
        ;;
    esac
}

# Every file in $1 (a list of paths) must contain pattern $2.
pam_files_have() {
    local f
    for f in $1; do grep -q "$2" "$f" || return 1; done
}

# Home = \\DC\Homes$\<user>, mounted at login by pam_mount with the Kerberos ticket.
pam_cifs_home() {
    install -m 644 "$CFG/home/pam_mount.conf.xml" /etc/security/pam_mount.conf.xml
    install -m 644 "$CFG/home/xdg-cache.sh" /etc/profile.d/mld-xdg-cache.sh
    pam_enable_mount
    pam_files_have "$PAM_SESSION_FILES" pam_mount.so || fail "pam_mount is not in $PAM_SESSION_FILES"
    pam_files_have "$PAM_AUTH_FILES" pam_mount.so || fail "pam_mount is not in $PAM_AUTH_FILES"
}

# NFS home (IDP=freeipa): autofs mounts <server>:/export/home/<user> on /home/mld/<user> (sec=krb5p) with the
# ticket of the login. ipa-client-install wrote the automount and the idmapd settings. No PAM module is necessary.
pam_nfs_home() {
    install -m 644 "$CFG/home/xdg-cache.sh" /etc/profile.d/mld-xdg-cache.sh
    case "$CLIENT_DISTRO" in
    ubuntu)
        pkg_install autofs nfs-common
        pam-auth-update --package --enable sss
        [ ! -f /usr/share/pam-configs/mkhomedir ] || pam-auth-update --package --disable mkhomedir
        ;;
    fedora) pkg_install autofs nfs-utils ;;
    esac
    systemctl enable --now nfs-client.target autofs.service
    systemctl is-active --quiet autofs.service || fail "autofs does not run"
    grep -qE '^automount:.*sss' /etc/nsswitch.conf || fail "nsswitch.conf has no sss for automount"
    # shellcheck disable=SC2086
    ! grep -qE 'pam_(mount|mkhomedir)\.so' $PAM_SESSION_FILES \
        || fail "pam_mount or pam_mkhomedir is in $PAM_SESSION_FILES"
}

# Local home: pam_mkhomedir makes /home/<user> at the first login.
pam_local_home() {
    rm -f /etc/profile.d/mld-xdg-cache.sh
    # IDP=freeipa clients have no pam_mount.
    [ "${IDP:-windows}" = freeipa ] || pam_disable_mount
    # A CIFS home from CIFS_HOME=1 stays mounted while the user has a session (systemd user manager).
    # Without pam_mount nothing unmounts it, and pam_mkhomedir does not make a local home over it.
    # findmnt and grep exit 1 when they find nothing. Under pipefail that is a failure, so collect first.
    local homes mp
    homes=$(findmnt -rn -t cifs -o TARGET | grep '^/home/' || true)
    for mp in $homes; do
        loginctl terminate-user "$(basename "$mp")" 2>/dev/null || true
        sleep 2
        umount "$mp" 2>/dev/null || umount -l "$mp"
        rmdir "$mp" 2>/dev/null || true
    done
    pam_enable_mkhomedir
    pam_files_have "$PAM_SESSION_FILES" mkhomedir.so || fail "pam_mkhomedir is not in $PAM_SESSION_FILES"
    # shellcheck disable=SC2086
    ! grep -q pam_mount.so $PAM_SESSION_FILES || fail "pam_mount is still in $PAM_SESSION_FILES"
}

phase_pam() {
    phase pam
    # HOME_MODE is in config.env only with IDP=freeipa. Windows clients: from CIFS_HOME.
    local mode="${HOME_MODE:-}"
    [ -n "$mode" ] || { if [ "${CIFS_HOME:-1}" = 1 ]; then mode=cifs; else mode=local; fi; }
    case "$mode" in
    cifs) pam_cifs_home ;;
    nfs) pam_nfs_home ;;
    local) pam_local_home ;;
    *) fail "unknown HOME_MODE '$mode'" ;;
    esac
    install -m 644 "$CFG/home/sshd-mld.conf" /etc/ssh/sshd_config.d/50-mld.conf
    # ssh.socket starts sshd at the first connection, so the service can be inactive. Then nothing must reload.
    systemctl try-reload-or-restart "$SSH_UNIT"
}
