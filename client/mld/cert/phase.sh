# shellcheck shell=bash
# PKI: lab CA, TPM group, machine token PIN, certificate autoenrollment.
# Sourced by mld-firstboot (client/mld/firstboot.sh): phase, fail, CFG, STATE and the config.env values are set.

# AD users make their own TPM keys (mld-cert user). The kernel resource manager device must be theirs.
# Numeric GID: udev cannot resolve AD groups (sssd) when it reads the rule.
pki_tpm_group() {
    # IDM_GROUP: the group name as the directory has it (FreeIPA: lower case).
    local group="${IDM_GROUP:-${LINUX_GROUP:-LinuxUsers}}" gid
    gid=$(getent group "$group" | cut -d: -f3)
    [ -n "$gid" ] || fail "group $group does not resolve"
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
    local v vars
    local CERT_PKGS
    case "$CLIENT_DISTRO" in
    ubuntu) CERT_PKGS=(tpm2-openssl curl certmonger libtpm2-pkcs11-1 libtpm2-pkcs11-tools libnss3-tools opensc) ;;
    fedora) CERT_PKGS=(tpm2-openssl curl certmonger tpm2-pkcs11 tpm2-pkcs11-tools nss-tools opensc) ;;
    esac
    # AD only: the template search (LDAP, impacket) and DCOM enrollment.
    if [ "${IDP:-windows}" = windows ]; then
        case "$CLIENT_DISTRO" in
        ubuntu) CERT_PKGS+=(python3-impacket ldap-utils libsasl2-modules-gssapi-mit) ;;
        fedora) CERT_PKGS+=(python3-impacket openldap-clients cyrus-sasl-gssapi) ;;
        esac
    fi
    pkg_install "${CERT_PKGS[@]}"
    command -v tpm2_ptool >/dev/null || fail "tpm2_ptool missing (package libtpm2-pkcs11-tools, Fedora tpm2-pkcs11-tools)"
    [ -x /usr/local/sbin/mld-cert ] || install -m 755 "$CFG/cert/cert.sh" /usr/local/sbin/mld-cert
    [ -x /usr/local/sbin/mld-cert-dcom ] || install -m 755 "$CFG/cert/cert-dcom.py" /usr/local/sbin/mld-cert-dcom
    pki_tpm_group
    # TPM-bound user files (keys, token store, PIN): one directory per user, made by the user (mld-cert, mld-autoenroll).
    install -d -m 1733 -o root -g root /var/lib/mld-users
    # config.env has printf %q values (bash 5.3 escapes ","). autoenroll.py does not remove the escapes.
    vars="DC_FQDN REALM PKI_ENROLL CLIENT_DISTRO CA_ANCHOR_DIR CA_ANCHOR_PREFIX IDP"
    [ "${IDP:-windows}" != windows ] || vars+=" CA_NAME DOMAIN_DN"
    for v in $vars; do printf "%s='%s'\n" "$v" "${!v:-}"; done > /etc/mld-cert.conf
    chmod 644 /etc/mld-cert.conf
    # IDP=freeipa: ipa-client-install puts the IPA CA into the system store, mld-policy into the Chrome policy.
    if [ "${IDP:-windows}" = windows ]; then
        mld-cert ca
        pki_wait_certsrv
    fi
    # Autoenrollment as on Windows: the templates come from AD (published, Autoenroll permission),
    # certmonger keeps the certificates, the keys are in the TPM token, the timer repeats every 8 h.
    pki_machine_pin
    # Label the store before the token is made: new files then get cert_t from the directory. Without this, the
    # running certmonger touched the new etc_t database before the restorecon below (AVC write, seen 2026-11-18).
    install -d -m 700 /etc/tpm2_pkcs11
    if [ "$CLIENT_DISTRO" = fedora ]; then restorecon -R /etc/tpm2_pkcs11 /etc/mld/pki; fi
    mld-autoenroll setup machine
    # fcontexts.list gives the token store and the NSS database type cert_t: certmonger_t writes there.
    if [ "$CLIENT_DISTRO" = fedora ]; then restorecon -R /etc/tpm2_pkcs11 /etc/mld/pki; fi
    mld-autoenroll machine
    systemctl enable --now mld-autoenroll.timer
    # Users: session certmonger + autoenrollment at login (systemd user units, all users; AD users only by UID).
    systemctl --global enable mld-autoenroll-user.timer
    mld-autoenroll status
}
