# shellcheck shell=bash
# Login: PAM with the CIFS home (pam_mount) or a local home, sshd.
# Sourced by mld-firstboot (client/mld/firstboot.sh): phase, fail, CFG, STATE and the config.env values are set.

# Home = \\DC\Homes$\<user>, mounted at login by pam_mount with the Kerberos ticket.
pam_cifs_home() {
    install -m 644 "$CFG/home/pam_mount.conf.xml" /etc/security/pam_mount.conf.xml
    install -m 644 "$CFG/home/xdg-cache.sh" /etc/profile.d/mld-xdg-cache.sh
    pam-auth-update --package --enable sss libpam-mount
    [ ! -f /usr/share/pam-configs/mkhomedir ] || pam-auth-update --package --disable mkhomedir
    grep -q pam_mount.so /etc/pam.d/common-session || fail "pam_mount is not in common-session"
    grep -q pam_mount.so /etc/pam.d/common-auth || fail "pam_mount is not in common-auth"
}

# Local home: pam_mkhomedir makes /home/<user> at the first login.
pam_local_home() {
    rm -f /etc/profile.d/mld-xdg-cache.sh
    pam-auth-update --package --disable libpam-mount
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
    pam-auth-update --package --enable sss mkhomedir
    grep -q pam_mkhomedir.so /etc/pam.d/common-session || fail "pam_mkhomedir is not in common-session"
    ! grep -q pam_mount.so /etc/pam.d/common-session || fail "pam_mount is still in common-session"
}

phase_pam() {
    phase pam
    if [ "${CIFS_HOME:-1}" = 1 ]; then pam_cifs_home; else pam_local_home; fi
    install -m 644 "$CFG/home/sshd-mld.conf" /etc/ssh/sshd_config.d/50-mld.conf
    # ssh.socket starts sshd at the first connection, so ssh.service can be inactive. Then nothing must reload.
    systemctl try-reload-or-restart ssh.service
}
