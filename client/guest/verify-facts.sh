# shellcheck shell=bash
# Runs in the client as root (build.sh guest_run). Needs PROBE_USER, DC_IP, PKI_ENROLL, MACHINE_TOKEN_PIN.
# Prints KEY=VALUE lines for client verify.
# config.env must not overwrite the values that guest_run passes in.
_keep="$(declare -p PROBE_USER DC_IP PKI_ENROLL MACHINE_TOKEN_PIN 2>/dev/null || true)"
. /etc/mld/config.env || { echo "missing /etc/mld/config.env: run ./build.sh client resume" >&2; exit 1; }
eval "$_keep"
. /etc/mld/distro.sh || { echo "missing /etc/mld/distro.sh: run ./build.sh client resume" >&2; exit 1; }
pkg_fact() {
    local v
    case "$CLIENT_DISTRO" in
    ubuntu)
        v=$(dpkg-query -W -f '${db:Status-Abbrev}${Version}' "$1" 2>/dev/null)
        [[ "$v" != "ii "* ]] || echo "installed ${v#ii }"
        ;;
    *)
        ! pkg_installed "$1" || echo "installed $(pkg_version "$1")"
        ;;
    esac
}
first_crypttab_field() { awk -v f="$1" '!/^[[:space:]]*#/ && NF { print $f; exit }' /etc/crypttab; }
name=$(first_crypttab_field 1)
src=$(first_crypttab_field 2)
case "$src" in UUID=*) dev=$(blkid -U "${src#UUID=}") ;; *) dev=$src ;; esac
# 2>&1: with a systemd-tpm2 token, cryptsetup writes the token details and the digests to stderr (Fedora 45,
# seen 2026-11-18). guest-exec.sh shows the guest stderr on the host terminal.
dump=$(cryptsetup luksDump "$dev" 2>&1)
root_dev=$(findmnt -no SOURCE /)

echo "sb=$(mokutil --sb-state 2>&1 | head -1)"
echo "luks_version=$(awk '/^Version:/ { print $2 }' <<<"$dump")"
echo "tokens=$(awk '/^Tokens:/ { t = 1; next } /^[A-Z]/ { t = 0 } t && /systemd-/ { printf "%s ", $2 }' <<<"$dump")"
echo "keyslots=$(awk '/^Keyslots:/ { k = 1; next } /^[A-Z]/ { k = 0 }
    k && /^  [0-9]+: luks2/ { n++ } END { print n + 0 }' <<<"$dump")"
echo "root_on_crypt=$(lsblk -no TYPE -s "$root_dev" | grep -qx crypt && echo yes || echo no)"
echo "plain_fs=$(lsblk -nrpo TYPE,MOUNTPOINTS | awk '$1 == "part" && NF > 1 { printf "%s ", $2 }')"
echo "crypttab=$(awk -v n="$name" '$1 == n { print $4 }' /etc/crypttab)"
if [ "${IDP:-windows}" = freeipa ]; then
    hp=$(klist -k /etc/krb5.keytab 2>/dev/null | awk 'NR > 3 && $2 ~ /^host\// { print $2; exit }')
    echo "ipa_host_principal=$hp"
    echo "ipa_kinit=$(KRB5CCNAME=MEMORY:verify kinit -k "$hp" 2>/dev/null && echo ok || echo failed)"
    echo "ipa_provider=$(sed -n 's/^[[:space:]]*id_provider[[:space:]]*=[[:space:]]*//p' \
        /etc/sssd/sssd.conf 2>/dev/null | head -1)"
    echo "ipa_ccache=$(sed -n 's/^[[:space:]]*default_ccache_name[[:space:]]*=[[:space:]]*//p' \
        /etc/krb5.conf.d/0-mld-ccache 2>/dev/null)"
    echo "autofs=$(systemctl is-active autofs 2>&1)"
else
    echo "realm=$(realm list --name-only 2>/dev/null | tr '\n' ' ')"
    # The machine account works (offline join and realm join): Samba logs on with the password in secrets.tdb.
    echo "testjoin=$(net ads testjoin -s /etc/mld/gpo/gpupdate.conf 2>&1 | tail -1)"
    echo "keytab=$(klist -k /etc/krb5.keytab 2>/dev/null | awk 'NR > 3 { print $2 }' | grep -c '\$@')"
    # Ticket for the own computer account: its encryption type is the one that the DC uses for this client.
    # A MEMORY cache lives in one process only: kinit, kvno and klist need a FILE cache (deleted after the check).
    cc=$(mktemp /tmp/mld-verify-cc.XXXXXX)
    # Runs in a subshell ($(...)): the export stays in it.
    machine_etype() {
        local m
        m="$(hostname -s | tr a-z A-Z)\$"
        export KRB5CCNAME="FILE:$cc"
        kinit -k -t /etc/krb5.keytab "$m" 2>/dev/null && kvno "$m" >/dev/null 2>&1 &&
            klist -e 2>/dev/null | awk -v p="$m@" '
                index($0, p) && !/Default principal/ { f = 1; next }
                f && /Etype/ { sub(/.*Etype \(skey, tkt\): /, ""); sub(/[[:space:]]+$/, ""); print; exit }'
    }
    echo "machine_etype=$(machine_etype)"
    rm -f "$cc"
fi
echo "probe_id=$(id "$PROBE_USER" 2>&1)"
echo "failed_units=$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{ printf "%s ", $1 }')"
admin_user=$(sed -n "s/^CLIENT_ADMIN=//p" /etc/mld/config.env 2>/dev/null | tr -d "'" | grep . || echo labadmin)
echo "admin_pw=$(passwd -S "$admin_user" 2>/dev/null | awk '{ print $1 "=" $2 }')"
echo "recovery=$( [ -s /var/lib/mld/recovery-key ] && echo present || echo absent)"
# Link DNS servers other than the DC. Empty = all queries go to the DC (global resolved server).
echo "link_dns=$(resolvectl dns 2>/dev/null | awk -F': ' -v dc="$DC_IP" '
    /^Link/ { n = split($2, a, " "); for (i = 1; i <= n; i++) if (a[i] != dc) printf "%s=%s ", $1, a[i] }')"
case "$CLIENT_DISTRO" in
ubuntu)
    echo "uu_pkg=$(pkg_fact unattended-upgrades)"
    echo "uu_periodic=$(apt-config dump --format '%v ' \
        APT::Periodic::Update-Package-Lists APT::Periodic::Unattended-Upgrade)"
    echo "uu_timers=$(systemctl is-enabled apt-daily.timer apt-daily-upgrade.timer mld-reboot.timer 2>&1 | tr '\n' ' ')"
    # The dry run prints the origins that unattended-upgrades really uses (50unattended-upgrades + 52mld-...).
    echo "uu_origins=$(timeout 300 unattended-upgrade --dry-run --debug 2>&1 |
        sed -n 's/^Allowed origins are: //p' | head -1)"
    ;;
fedora)
    echo "upd_pkg=$(pkg_fact dnf5-plugin-automatic)"
    echo "upd_timer=$(systemctl is-enabled dnf5-automatic.timer mld-reboot.timer 2>&1 | tr '\n' ' ')"
    # The override file of dnf5-automatic(8). The deprecated location must not exist: its order is not documented.
    echo "upd_conf=$(sed -n 's/^apply_updates[[:space:]]*=[[:space:]]*//p' /etc/dnf/automatic.conf 2>/dev/null |
        tail -1)"
    echo "upd_conf_deprecated=$( [ -e /etc/dnf/dnf5-plugins/automatic.conf ] && echo present || echo absent)"
    echo "upd_repos=$(dnf repolist --enabled -q 2>/dev/null | awk '$1 != "repo" { printf "%s ", $1 }')"
    echo "upd_dropin=$( [ -e /etc/systemd/system/dnf5-automatic.service.d/mld.conf ] && echo present || echo absent)"
    echo "selinux=$(getenforce 2>&1)"
    if avc=$(/usr/local/libexec/mld-avc-report 2>/dev/null); then
        echo "avc_unexpected=$(printf '%s' "$avc" | awk 'NF { n++ } END { print n + 0 }')"
    else
        echo "avc_unexpected=error"
    fi
    echo "authselect=$(authselect current --raw 2>&1)"
    echo "greeter_unit=$(systemctl is-active plasmalogin.service 2>&1)"
    echo "greeter_dropin=$( [ -e /etc/plasmalogin.conf.d/90-mld.conf ] && echo present || echo absent)"
    ;;
esac
echo "snx_pkg=$(pkg_fact snx-rs)"
echo "snx_active=$(systemctl is-active snx-rs.service 2>/dev/null)"
echo "snx_menu=$( [ -e /usr/share/applications/snx-rs-gui.desktop ] && echo present || echo absent)"
echo "snx_dropin=$(systemctl show -p Environment --value snx-rs.service 2>/dev/null)"
# The same path as the snx-rs service: root, the tpm2-pkcs11 driver, login with the PIN of the profile.
if [ "$PKI_ENROLL" != none ]; then
    p11() {
        TPM2_PKCS11_STORE=/etc/tpm2_pkcs11 TSS2_LOG=all+NONE pkcs11-tool --module "$PKCS11_DIR/libtpm2_pkcs11.so" "$@"
    }
    certs=$(p11 --login --pin "$MACHINE_TOKEN_PIN" --list-objects --type cert 2>&1)
    id=$(awk '$1 == "ID:" { print $2; exit }' <<<"$certs")
    echo "machine_p11_certs=$(grep -c 'Certificate Object' <<<"$certs")"
    echo "machine_p11_id=$id"
    echo "machine_p11_sign=$(printf x |
        p11 --login --pin "$MACHINE_TOKEN_PIN" --sign --id "$id" --mechanism SHA256-RSA-PKCS 2>/dev/null | wc -c)"
fi
echo "firefox_pkg=$(pkg_fact firefox)"
case "$CLIENT_DISTRO" in
ubuntu)
    echo "firefox_origin=$(apt-cache policy firefox 2>/dev/null | awk '/\*\*\*/ { f = 1; next } f { print $2; exit }')"
    ;;
fedora) echo "firefox_vendor=$(rpm -q --qf '%{VENDOR}' firefox 2>/dev/null)" ;;
esac
echo "chrome_pkg=$(pkg_fact google-chrome-stable)"
echo "o365_launchers=$(ls /usr/share/applications/mld-o365-*.desktop 2>/dev/null | wc -l)"
echo "o365_icons=$(ls /usr/share/icons/hicolor/scalable/apps/mld-o365-*.svg 2>/dev/null | wc -l)"
py_off='import json, sys; d = json.load(open(sys.argv[1])); '
py_off+='print(" ".join(k for k, v in sorted(d.items()) if v is False))'
echo "chrome_policy=$(python3 -c "$py_off" /etc/opt/chrome/policies/managed/mld.json 2>&1)"
echo "o365_policy=$( [ -e /etc/opt/chrome/policies/managed/mld-o365.json ] && echo present || echo absent)"
echo "de_installed=$( [ -x /usr/bin/gnome-shell ] && printf gnome; [ -x /usr/bin/plasmashell ] && printf kde )"
dm_id=$(systemctl show -p Id --value display-manager.service 2>/dev/null)
echo "dm_unit=$dm_id/$(systemctl is-active display-manager.service 2>/dev/null)"
echo "sddm_userlist=$(sed -n 's/^MaximumUid=//p' /etc/sddm.conf.d/90-mld.conf 2>/dev/null)"
# SDDM reads /etc/sddm.conf.d in name order, the last value wins.
echo "sddm_theme=$(cat /etc/sddm.conf.d/*.conf 2>/dev/null | sed -n 's/^Current=//p' | tail -1)"
echo "sddm_bg=$(sed -n 's/^background=//p' /usr/share/sddm/themes/breeze/theme.conf.user 2>/dev/null)"
case "$CLIENT_DISTRO" in
ubuntu) echo "plymouth_theme=$(readlink -f /usr/share/plymouth/themes/default.plymouth)" ;;
# Fedora has no default.plymouth link. Without arguments, the command prints the theme name.
fedora) echo "plymouth_theme=$(plymouth-set-default-theme 2>/dev/null)" ;;
esac
echo "plymouth_initrd=$(grep -c 'plymouth/themes/mld/' <<<"$(lsinitrd "$(initrd_path "$(uname -r)")" 2>/dev/null)")"
echo "kde_pins=$(grep -c 'mld-o365-outlook.desktop' \
    /usr/share/plasma/shells/org.kde.plasma.desktop/contents/updates/mld-pins.js 2>/dev/null)"
echo "plasma_shadow=$( [ -e /usr/local/share/plasma/shells/org.kde.plasma.desktop ] && echo present || echo absent)"
echo "dock_default=$(DCONF_PROFILE=user dconf read /org/gnome/shell/favorite-apps 2>&1)"
echo "desktop_unit=$(systemctl --global is-enabled mld-desktop.service 2>&1)"
echo "ca_ad=$(ls "$CA_ANCHOR_DIR"/${CA_ANCHOR_PREFIX}*.crt 2>/dev/null | wc -l)"
py_ca='import json, sys; print(len(json.load(open(sys.argv[1]))["CACertificates"]))'
echo "ca_chrome=$(python3 -c "$py_ca" /etc/opt/chrome/policies/managed/mld-ca.json 2>&1)"
echo "p11kit_trust=$( [ -e "$PKCS11_DIR/p11-kit-trust.so" ] && echo present || echo absent)"
echo "ca_legacy=$( [ "$CLIENT_DISTRO" = ubuntu ] && [ -e /usr/local/share/ca-certificates/mld-ca.crt ] &&
    echo present || echo absent)"
cert_fqdn=$(. /etc/mld-cert.conf 2>/dev/null; echo "$DC_FQDN")
echo "certsrv_tls=$(curl -s -o /dev/null -w '%{http_code}' "https://$cert_fqdn/certsrv/" 2>&1)"
echo "gpo_chrome=$(grep -ho '"AuthServerAllowlist": *"[^"]*"' /etc/opt/chrome/policies/managed/*.json 2>/dev/null |
    head -1)"
py_ff='import json, sys; d = json.load(open(sys.argv[1])).get("policies", {}); '
py_ff+='print(d.get("Authentication", {}).get("SPNEGO"), list(d.get("SecurityDevices", {}).get("Add", {})))'
echo "gpo_firefox=$(python3 -c "$py_ff" /etc/firefox/policies/policies.json 2>&1)"
echo "gpo_timer=$(systemctl is-enabled mld-gpupdate.timer 2>&1)"
echo "policy_timer=$(systemctl is-enabled mld-policy.timer 2>&1)"
