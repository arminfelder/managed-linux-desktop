# shellcheck shell=bash
# Browser policy from the FreeIPA server (IDP=freeipa; IDP=windows uses the gpo topic). mld-policy pulls it,
# mld-policy.timer refreshes it every 90 min.
# Sourced by mld-firstboot (client/mld/firstboot.sh): phase, fail, CFG, STATE and the config.env values are set.

phase_policy() {
    local p11kit=""
    phase policy
    # Fedora Firefox reads the system store (with the IPA CA from ipa-client-install) through p11-kit-proxy.
    # A second p11-kit-trust device is not necessary there.
    [ "$CLIENT_DISTRO" = fedora ] || p11kit="$PKCS11_DIR/p11-kit-trust.so"
    printf '%s\n' "# Written by mld-firstboot (phase_policy)." "DC_FQDN=$DC_FQDN" \
        "HOST_FQDN=$(hostname -s | tr '[:upper:]' '[:lower:]').${DOMAIN,,}" "P11KIT_TRUST=$p11kit" \
        > "$CFG/policy/policy.conf"
    mld-policy || fail "mld-policy: no policy from https://$DC_FQDN/mld-policy (see the lines above)"
    grep -qs '"AuthServerAllowlist"' /etc/opt/chrome/policies/managed/mld-policy-*.json \
        || fail "no AuthServerAllowlist from the IPA server in /etc/opt/chrome/policies/managed"
    grep -qs '"SPNEGO"' /etc/firefox/policies/policies.json \
        || fail "no Authentication.SPNEGO from the IPA server in /etc/firefox/policies/policies.json"
    systemctl daemon-reload
    systemctl reset-failed mld-policy.service 2>/dev/null || true
    systemctl enable --now mld-policy.timer
}
