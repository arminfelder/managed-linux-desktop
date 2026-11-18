# shellcheck shell=bash
# DNS to the DC, AD join (offline domain join with a djoin blob, Samba membership), sssd.
# Sourced by mld-firstboot (client/mld/firstboot.sh): phase, fail, CFG, STATE and the config.env values are set.

# The dracut module systemd-networkd writes /run/systemd/network/zzzz-dracut-default.network (DHCP=yes) in the initrd.
# networkd keeps it after switch-root, manages the NIC and takes the DHCP DNS server (libvirt).
# resolved then sends each query to libvirt and to the DC, and uses the first answer.
# The /etc mask hides the /run file. Then NetworkManager manages the NIC (netplan profile netplan-lan).
# That profile also sends the DHCP DNS server: NetworkManager ignores the netplan use-dns: false.
# dns=none alone still sends link DNS to resolved (log: "dns=none,systemd-resolved"). systemd-resolved=false stops it.
# Only the global DC server stays.
dns_configure_ubuntu() {
    install -d -m 755 /etc/systemd/resolved.conf.d
    printf '[Resolve]\nDNS=%s\nDomains=%s ~.\n' "$DC_IP" "$DOMAIN" > /etc/systemd/resolved.conf.d/90-mld.conf
    chmod 755 /etc/systemd/resolved.conf.d; chmod 644 /etc/systemd/resolved.conf.d/90-mld.conf
    install -d -m 755 /etc/systemd/network /etc/NetworkManager/conf.d
    ln -sfn /dev/null /etc/systemd/network/zzzz-dracut-default.network
    printf '[main]\ndns=none\nsystemd-resolved=false\n' > /etc/NetworkManager/conf.d/90-mld-dns.conf
    chmod 644 /etc/NetworkManager/conf.d/90-mld-dns.conf
    networkctl reload
    nmcli general reload conf
    # networkd manages no link now, so its wait-online unit waits 2 min at each boot, then fails.
    systemctl disable --now systemd-networkd-wait-online.service 2>/dev/null || true
    systemctl mask systemd-networkd-wait-online.service
    systemctl reset-failed systemd-networkd-wait-online.service 2>/dev/null || true
    systemctl restart systemd-resolved
    nm-online -q -t 60 || true
    # With dns=none, NetworkManager does not remove the servers that it set before.
    local dev
    for dev in $(nmcli -t -f DEVICE,TYPE device | awk -F: '$2 == "ethernet" { print $1 }'); do
        resolvectl revert "$dev" || true
    done
}

# Fedora: NetworkManager and systemd-resolved are the only DNS owners, there is no networkd mask.
# NetworkManager sends no DNS to resolved (systemd-resolved=false). The global resolved server is the only DNS source.
# The NIC profile also lists the DC, for tools that read the profile.
dns_configure_fedora() {
    install -d -m 755 /etc/systemd/resolved.conf.d /etc/NetworkManager/conf.d
    printf '[Resolve]\nDNS=%s\nDomains=%s ~.\n' "$DC_IP" "$DOMAIN" > /etc/systemd/resolved.conf.d/90-mld.conf
    chmod 644 /etc/systemd/resolved.conf.d/90-mld.conf
    printf '[main]\ndns=none\nsystemd-resolved=false\n' > /etc/NetworkManager/conf.d/90-mld-dns.conf
    chmod 644 /etc/NetworkManager/conf.d/90-mld-dns.conf
    nmcli general reload conf
    systemctl restart systemd-resolved
    nm-online -q -t 60 || true
    local dev con
    for dev in $(nmcli -t -f DEVICE,TYPE device | awk -F: '$2 == "ethernet" { print $1 }'); do
        con=$(nmcli -g GENERAL.CON-UUID device show "$dev")
        [ -n "$con" ] || continue
        nmcli connection modify "$con" ipv4.ignore-auto-dns yes ipv4.dns "$DC_IP" ipv4.dns-search "$DOMAIN"
        nmcli device reapply "$dev" || nmcli connection up "$con"
        resolvectl revert "$dev" || true
    done
}

dns_configure() {
    case "$CLIENT_DISTRO" in
    ubuntu) dns_configure_ubuntu ;;
    fedora) dns_configure_fedora ;;
    esac
}

# Prints "Link N (dev)=server" for each link DNS server that is not the DC.
dns_foreign_servers() {
    resolvectl dns 2>/dev/null | awk -F": " -v dc="$DC_IP" \
        '/^Link/ { n = split($2, a, " "); for (i = 1; i <= n; i++) if (a[i] != dc) print $1 "=" a[i] }'
}

phase_dns() {
    phase dns
    dns_configure
    local bad=""
    for _ in $(seq 1 30); do
        bad=$(dns_foreign_servers)
        [ -n "$bad" ] || break
        sleep 2
    done
    [ -z "$bad" ] || fail "link DNS servers other than the DC: $bad"
    for _ in $(seq 1 60); do
        host -t SRV "_ldap._tcp.$DOMAIN" >/dev/null 2>&1 && break
        sleep 10
    done
    host -t SRV "_ldap._tcp.$DOMAIN" || fail "no _ldap._tcp.$DOMAIN SRV record (DC down or wrong DNS)"
}

# Offline domain join, as for Windows clients (djoin.exe): the blob from the DC holds the computer account and its
# password, so the client needs no join password. Samba writes the password to secrets.tdb (samba-gpupdate uses it)
# and the keytab for sssd. No kpasswd is used: Server 2025 KPASSWD replies break adcli ("Message stream modified").
phase_join() {
    local blob="$CFG/odj.txt" conf="$CFG/gpo/gpupdate.conf"
    phase join
    install -m 644 "$CFG/ad/krb5.conf" /etc/krb5.conf
    case "$CLIENT_DISTRO" in
    ubuntu) pkg_install samba-common-bin ;;
    fedora) pkg_install samba-common-tools ;;
    esac
    [ -s "$blob" ] \
        || fail "no offline join blob $blob. Make one with djoin /provision (build.sh client odj $(hostname -s))," \
                "then run: sudo mld-firstboot join FILE"
    net offlinejoin requestodj loadfile="$blob" -s "$conf" \
        || fail "net offlinejoin requestodj failed (blob for an other computer name than $(hostname -s)?)"
    net ads keytab create -s "$conf" --option='kerberos method=secrets and keytab' || fail "keytab not made"
    net ads testjoin -s "$conf" || fail "net ads testjoin failed after the offline join"
    shred -u "$blob"
    touch "$STATE/join.done"
}

phase_sssd() {
    phase sssd
    if [ "${IDP:-windows}" = freeipa ]; then
        ipa_sssd_settings
    else
        # Also on clients that joined before a krb5.conf change: phase_join runs only once.
        install -m 644 "$CFG/ad/krb5.conf" /etc/krb5.conf
        install -m 600 "$CFG/ad/sssd.conf" /etc/sssd/sssd.conf
        # sssd.conf starts the responders (services = nss, pam; the AD provider adds pac).
        # The socket units for the same responders refuse to start then, and show FAILED at each boot.
        systemctl disable --now sssd-nss.socket sssd-pam.socket sssd-pac.socket 2>/dev/null || true
        systemctl reset-failed sssd-nss.socket sssd-pam.socket sssd-pac.socket 2>/dev/null || true
    fi
    systemctl restart sssd
    # The Fedora default profile is "local": nsswitch has no sss, so getent cannot resolve AD names.
    # phase_pam selects the final profile (custom/mld or sssd with-mkhomedir) later.
    if [ "$CLIENT_DISTRO" = fedora ]; then
        case "$(authselect current --raw 2>/dev/null || true)" in
        sssd|sssd\ *|custom/mld|custom/mld\ *) ;;
        *) authselect select sssd --force ;;
        esac
    fi
    for _ in $(seq 1 30); do getent passwd "$PROBE_USER" >/dev/null && break; sleep 5; done
    getent passwd "$PROBE_USER" || fail "sssd cannot resolve $PROBE_USER"
}
