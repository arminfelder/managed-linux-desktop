# shellcheck shell=bash
# FreeIPA join (one-time password) and the sssd/krb5 settings on top of ipa-client-install. IDP=freeipa only.
# Sourced by mld-firstboot (client/mld/firstboot.sh): phase, fail, CFG, STATE and the config.env values are set.

# build.sh made the host entry with a one-time password (ipa/guest/host-add.sh). The password is good for one join only.
phase_join_ipa() {
    local otp="$CFG/ipa-otp.txt" fqdn
    phase join
    fqdn="$(hostname -s | tr '[:upper:]' '[:lower:]').${DOMAIN,,}"
    pkg_install freeipa-client
    if [ -f /etc/ipa/default.conf ]; then
        echo "ipa-client-install ran before: skipped"
    else
        [ -s "$otp" ] || fail "no one-time password $otp. Make a new client ISO (build.sh client iso) or join by hand"
        ipa-client-install -U --password "$(cat "$otp")" --domain "${DOMAIN,,}" --server "$DC_FQDN" --realm "$REALM" \
            --hostname "$fqdn" --ntp-pool pool.ntp.org --automount-location=default \
            || fail "ipa-client-install failed (see /var/log/ipaclient-install.log)"
    fi
    [ ! -e "$otp" ] || shred -u "$otp"
    KRB5CCNAME="MEMORY:join" kinit -k "host/$fqdn" || fail "no host ticket with /etc/krb5.keytab"
    touch "$STATE/join.done"
}

# ipa-client-install writes sssd.conf and krb5.conf. The lab changes go into drop-ins only.
ipa_sssd_settings() {
    local s
    # The ticket cache must be a file: rpc.gssd (NFS krb5p) and the user units read /tmp/krb5cc_<uid>.
    # "0-" sorts before kcm_default_ccache (Fedora): the first value of a krb5 relation wins. No dot in the name:
    # includedir reads only names without a dot.
    install -d -m 755 /etc/krb5.conf.d
    printf '[libdefaults]\n    default_ccache_name = FILE:/tmp/krb5cc_%%{uid}\n' > /etc/krb5.conf.d/0-mld-ccache
    chmod 644 /etc/krb5.conf.d/0-mld-ccache
    install -d -m 711 /etc/sssd/conf.d
    # Without renewal the NFS home becomes unreadable when the ticket of the login expires.
    printf '%s\n' "[domain/${DOMAIN,,}]" 'krb5_ccname_template = FILE:/tmp/krb5cc_%U' \
        'krb5_renewable_lifetime = 7d' 'krb5_renew_interval = 60m' > /etc/sssd/conf.d/50-mld.conf
    chmod 600 /etc/sssd/conf.d/50-mld.conf
    # sssd.conf starts the responders (services = nss, pam, ssh, sudo, autofs). The socket units of the same
    # responders refuse to start then: on Ubuntu all six show failed after the join (seen 2026-11-18).
    for s in nss pam pac ssh sudo autofs; do
        systemctl disable --now "sssd-$s.socket" 2>/dev/null || true
        systemctl reset-failed "sssd-$s.socket" 2>/dev/null || true
    done
}
