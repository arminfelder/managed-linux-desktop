# shellcheck shell=bash
# Phase 1: FreeIPA server with integrated DNS and CA. Sourced by run.sh.
firewall-cmd --permanent --add-service=freeipa-4 --add-service=dns --add-service=nfs >/dev/null
firewall-cmd --reload >/dev/null
if [ -f /etc/ipa/default.conf ]; then
    log "ipa-server-install ran before: skipped"
else
    # --allow-zone-overlap: the libvirt dnsmasq of the lab network also answers for the reverse zone.
    # Without it: "DNSZoneAlreadyExists: DNS zone ... already exists in DNS". Seen 2026-11-18.
    # --no-dnssec-validation: the dnsmasq forwarder gives no DNSSEC data. --idstart 200000: the client ranges
    # (pam, xdg-cache, desktop) start at UID 200000.
    ipa-server-install -U --realm "$REALM" --domain "$DOMAIN" --hostname "$DC_FQDN" --ip-address "$DC_IP" \
        --ds-password "$IPA_DM_PW" --admin-password "$ADMIN_PW" \
        --setup-dns --forwarder "$NET_GW" --forward-policy=only --no-dnssec-validation --allow-zone-overlap \
        --reverse-zone "$REVERSE_ZONE." --idstart 200000 --idmax 299999 --ntp-pool "$NTP_POOL"
fi
ipactl status
