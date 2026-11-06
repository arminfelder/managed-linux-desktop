# shellcheck shell=bash
# Group Policy: GPO "MLD Linux Clients" (DC phase 8) through samba-gpupdate, refreshed by mld-gpupdate.timer.
# Sourced by mld-firstboot (client/mld/firstboot.sh): phase, fail, CFG, STATE and the config.env values are set.

phase_gpo() {
    phase gpo
    # samba-dsdb-modules has the ldb backend ildap. Without it, ldap:// uses the plain OpenLDAP module from libldb2:
    # no bind with the machine credentials, and samba-gpupdate fails ("a successful bind must be completed").
    pkg_install python3-samba samba-dsdb-modules
    mld-gpupdate --force
    # The two Kerberos settings show that the GPO came through (Chrome: one file per GPO, Firefox: one file).
    grep -qs '"AuthServerAllowlist"' /etc/opt/chrome/policies/managed/*.json \
        || fail "no AuthServerAllowlist from the GPO in /etc/opt/chrome/policies/managed"
    grep -qs '"SPNEGO"' /etc/firefox/policies/policies.json \
        || fail "no Authentication.SPNEGO from the GPO in /etc/firefox/policies/policies.json"
    # A timer run during phase_dns can fail. The run above replaces it.
    systemctl reset-failed mld-gpupdate.service 2>/dev/null || true
    systemctl enable --now mld-gpupdate.timer
}
