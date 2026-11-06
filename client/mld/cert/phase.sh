# shellcheck shell=bash
# PKI: lab CA, TPM group, machine token PIN, certificate autoenrollment.
# Sourced by mld-firstboot (client/mld/firstboot.sh): phase, fail, CFG, STATE and the config.env values are set.

# AD users make their own TPM keys (mld-cert user). The kernel resource manager device must be theirs.
# Numeric GID: udev cannot resolve AD groups (sssd) when it reads the rule.
pki_tpm_group() {
    local gid; gid=$(getent group "${LINUX_GROUP:-LinuxUsers}" | cut -d: -f3)
    [ -n "$gid" ] || fail "group ${LINUX_GROUP:-LinuxUsers} does not resolve"
    # 70-: after 60-tpm-udev.rules (package tpm-udev), which sets group tss. The last rule wins.
    rm -f /etc/udev/rules.d/60-mld-tpm.rules
    printf 'KERNEL=="tpmrm0", GROUP="%s", MODE="0660"\n' "$gid" > /etc/udev/rules.d/70-mld-tpm.rules
    udevadm control --reload
    udevadm trigger --name-match=/dev/tpmrm0
    udevadm settle
    [ "$(stat -c %g /dev/tpmrm0)" = "$gid" ] || fail "/dev/tpmrm0 group is $(stat -c %G /dev/tpmrm0), not $gid"
}

# The machine token PIN is the same on all clients and is not a secret: the root-only store protects the key.
# The snx-rs service (root) uses the machine certificate with this PIN from the user profile, without a prompt.
pki_machine_pin() {
    local f=/etc/mld/pki/token.pin old
    install -d -m 700 /etc/mld/pki
    if [ -s "$f" ]; then
        old=$(tr -d '\n' < "$f")
        [ "$old" != "$MACHINE_TOKEN_PIN" ] || return 0
        if TSS2_LOG=all+NONE tpm2_ptool listobjects --label mld-machine --path /etc/tpm2_pkcs11 >/dev/null 2>&1; then
            TSS2_LOG=all+NONE tpm2_ptool changepin --user user --old "$old" --new "$MACHINE_TOKEN_PIN" \
                --label mld-machine --path /etc/tpm2_pkcs11 >/dev/null
            echo "machine token PIN changed to MACHINE_TOKEN_PIN"
        fi
    fi
    ( umask 077; printf '%s' "$MACHINE_TOKEN_PIN" > "$f" )
}

# After a DC start, AD and DNS answer before certsrv (IIS). A request then ends as CA_UNREACHABLE
# ("curl: Empty reply from server"). certsrv answers 401 (Negotiate) when it is ready. Needs the CA from mld-cert ca.
pki_wait_certsrv() {
    [ "$PKI_ENROLL" = web ] || return 0
    local code=""
    for _ in $(seq 1 60); do
        code=$(curl -s -o /dev/null -w '%{http_code}' "https://$DC_FQDN/certsrv/" || true)
        case "$code" in 401|200) echo "certsrv answers (HTTP $code)"; return 0 ;; esac
        sleep 10
    done
    fail "certsrv https://$DC_FQDN/certsrv/ does not answer after 10 min (HTTP '$code')"
}

phase_pki() {
    phase pki
    # A client from before the PKI change gets the packages and tools here (client resume).
    local v
    pkg_install tpm2-openssl python3-impacket curl ldap-utils libsasl2-modules-gssapi-mit \
        certmonger libtpm2-pkcs11-1 libtpm2-pkcs11-tools libnss3-tools opensc
    command -v tpm2_ptool >/dev/null || fail "tpm2_ptool missing (package libtpm2-pkcs11-tools)"
    [ -x /usr/local/sbin/mld-cert ] || install -m 755 "$CFG/cert/cert.sh" /usr/local/sbin/mld-cert
    [ -x /usr/local/sbin/mld-cert-dcom ] || install -m 755 "$CFG/cert/cert-dcom.py" /usr/local/sbin/mld-cert-dcom
    pki_tpm_group
    # TPM-bound user files (keys, token store, PIN): one directory per user, made by the user (mld-cert, mld-autoenroll).
    install -d -m 1733 -o root -g root /var/lib/mld-users
    # config.env has printf %q values (bash 5.3 escapes ","). autoenroll.py does not remove the escapes.
    for v in DC_FQDN REALM CA_NAME DOMAIN_DN PKI_ENROLL; do printf "%s='%s'\n" "$v" "${!v}"; done > /etc/mld-cert.conf
    chmod 644 /etc/mld-cert.conf
    mld-cert ca
    pki_wait_certsrv
    # Autoenrollment as on Windows: the templates come from AD (published, Autoenroll permission),
    # certmonger keeps the certificates, the keys are in the TPM token, the timer repeats every 8 h.
    pki_machine_pin
    mld-autoenroll setup machine
    mld-autoenroll machine
    systemctl enable --now mld-autoenroll.timer
    # Users: session certmonger + autoenrollment at login (systemd user units, all users; AD users only by UID).
    systemctl --global enable mld-autoenroll-user.timer
    mld-autoenroll status
}
