# shellcheck shell=bash
# Runs in the client as root (build.sh guest_run). Needs PROBE_USER, DC_IP, PKI_ENROLL, MACHINE_TOKEN_PIN. Prints KEY=VALUE lines for client verify.
first_crypttab_field() { awk -v f="$1" '!/^[[:space:]]*#/ && NF { print $f; exit }' /etc/crypttab; }
name=$(first_crypttab_field 1)
src=$(first_crypttab_field 2)
case "$src" in UUID=*) dev=$(blkid -U "${src#UUID=}") ;; *) dev=$src ;; esac
dump=$(cryptsetup luksDump "$dev")
root_dev=$(findmnt -no SOURCE /)

echo "sb=$(mokutil --sb-state 2>&1 | head -1)"
echo "luks_version=$(awk '/^Version:/ { print $2 }' <<<"$dump")"
echo "tokens=$(awk '/^Tokens:/ { t = 1; next } /^[A-Z]/ { t = 0 } t && /systemd-/ { printf "%s ", $2 }' <<<"$dump")"
echo "keyslots=$(awk '/^Keyslots:/ { k = 1; next } /^[A-Z]/ { k = 0 } k && /^  [0-9]+: luks2/ { n++ } END { print n + 0 }' <<<"$dump")"
echo "root_on_crypt=$(lsblk -no TYPE -s "$root_dev" | grep -qx crypt && echo yes || echo no)"
echo "plain_fs=$(lsblk -nrpo TYPE,MOUNTPOINTS | awk '$1 == "part" && NF > 1 { printf "%s ", $2 }')"
echo "crypttab=$(awk -v n="$name" '$1 == n { print $4 }' /etc/crypttab)"
echo "realm=$(realm list --name-only 2>/dev/null | tr '\n' ' ')"
# The machine account works (offline join and realm join): Samba logs on with the password in secrets.tdb.
echo "testjoin=$(net ads testjoin -s /etc/mld/gpo/gpupdate.conf 2>&1 | tail -1)"
echo "keytab=$(klist -k /etc/krb5.keytab 2>/dev/null | awk 'NR > 3 { print $2 }' | grep -c '\$@')"
# Ticket for the own computer account: its encryption type is the one that the DC uses for this client.
# A MEMORY cache lives in one process only: kinit, kvno and klist need a FILE cache (deleted after the check).
cc=$(mktemp /tmp/mld-verify-cc.XXXXXX)
echo "machine_etype=$(m="$(hostname -s | tr a-z A-Z)\$"; export KRB5CCNAME="FILE:$cc"; kinit -k -t /etc/krb5.keytab "$m" 2>/dev/null && kvno "$m" >/dev/null 2>&1 && klist -e 2>/dev/null | awk -v p="$m@" 'index($0, p) && !/Default principal/ { f = 1; next } f && /Etype/ { sub(/.*Etype \(skey, tkt\): /, ""); sub(/[[:space:]]+$/, ""); print; exit }')"
rm -f "$cc"
echo "probe_id=$(id "$PROBE_USER" 2>&1)"
echo "failed_units=$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{ printf "%s ", $1 }')"
echo "admin_pw=$(passwd -S "$(sed -n "s/^CLIENT_ADMIN=//p" /etc/mld/config.env 2>/dev/null | tr -d "'" | grep . || echo labadmin)" 2>/dev/null | awk '{ print $1 "=" $2 }')"
echo "recovery=$( [ -s /var/lib/mld/recovery-key ] && echo present || echo absent)"
# Link DNS servers other than the DC. Empty = all queries go to the DC (global resolved server).
echo "link_dns=$(resolvectl dns 2>/dev/null | awk -F': ' -v dc="$DC_IP" '
    /^Link/ { n = split($2, a, " "); for (i = 1; i <= n; i++) if (a[i] != dc) printf "%s=%s ", $1, a[i] }')"
echo "uu_pkg=$(dpkg-query -W -f '${db:Status-Abbrev}${Version}' unattended-upgrades 2>/dev/null)"
echo "uu_periodic=$(apt-config dump --format '%v ' APT::Periodic::Update-Package-Lists APT::Periodic::Unattended-Upgrade)"
echo "uu_timers=$(systemctl is-enabled apt-daily.timer apt-daily-upgrade.timer mld-reboot.timer 2>&1 | tr '\n' ' ')"
# The dry run prints the origins that unattended-upgrades really uses (50unattended-upgrades + 52mld-...).
echo "uu_origins=$(timeout 300 unattended-upgrade --dry-run --debug 2>&1 | sed -n 's/^Allowed origins are: //p' | head -1)"
echo "snx_pkg=$(dpkg-query -W -f '${db:Status-Abbrev}${Version}' snx-rs 2>/dev/null)"
echo "snx_active=$(systemctl is-active snx-rs.service 2>/dev/null)"
echo "snx_menu=$( [ -e /usr/share/applications/snx-rs-gui.desktop ] && echo present || echo absent)"
echo "snx_dropin=$(systemctl show -p Environment --value snx-rs.service 2>/dev/null)"
# The same path as the snx-rs service: root, the tpm2-pkcs11 driver, login with the PIN of the profile.
if [ "$PKI_ENROLL" != none ]; then
    p11() { TPM2_PKCS11_STORE=/etc/tpm2_pkcs11 TSS2_LOG=all+NONE pkcs11-tool --module /usr/lib/x86_64-linux-gnu/pkcs11/libtpm2_pkcs11.so "$@"; }
    certs=$(p11 --login --pin "$MACHINE_TOKEN_PIN" --list-objects --type cert 2>&1)
    id=$(awk '$1 == "ID:" { print $2; exit }' <<<"$certs")
    echo "machine_p11_certs=$(grep -c 'Certificate Object' <<<"$certs")"
    echo "machine_p11_id=$id"
    echo "machine_p11_sign=$(printf x | p11 --login --pin "$MACHINE_TOKEN_PIN" --sign --id "$id" --mechanism SHA256-RSA-PKCS 2>/dev/null | wc -c)"
fi
echo "firefox_pkg=$(dpkg-query -W -f '${db:Status-Abbrev}${Version}' firefox 2>/dev/null)"
echo "firefox_origin=$(apt-cache policy firefox 2>/dev/null | awk '/\*\*\*/ { f = 1; next } f { print $2; exit }')"
echo "chrome_pkg=$(dpkg-query -W -f '${db:Status-Abbrev}${Version}' google-chrome-stable 2>/dev/null)"
echo "o365_launchers=$(ls /usr/share/applications/mld-o365-*.desktop 2>/dev/null | wc -l)"
echo "o365_icons=$(ls /usr/share/icons/hicolor/scalable/apps/mld-o365-*.svg 2>/dev/null | wc -l)"
echo "chrome_policy=$(python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); print(" ".join(k for k, v in sorted(d.items()) if v is False))' /etc/opt/chrome/policies/managed/mld.json 2>&1)"
echo "o365_policy=$( [ -e /etc/opt/chrome/policies/managed/mld-o365.json ] && echo present || echo absent)"
echo "de_installed=$( [ -x /usr/bin/gnome-shell ] && printf gnome; [ -x /usr/bin/plasmashell ] && printf kde )"
echo "dm_unit=$(systemctl show -p Id --value display-manager.service 2>/dev/null)/$(systemctl is-active display-manager.service 2>/dev/null)"
echo "sddm_userlist=$(sed -n 's/^MaximumUid=//p' /etc/sddm.conf.d/90-mld.conf 2>/dev/null)"
# SDDM reads /etc/sddm.conf.d in name order, the last value wins.
echo "sddm_theme=$(cat /etc/sddm.conf.d/*.conf 2>/dev/null | sed -n 's/^Current=//p' | tail -1)"
echo "sddm_bg=$(sed -n 's/^background=//p' /usr/share/sddm/themes/breeze/theme.conf.user 2>/dev/null)"
echo "plymouth_theme=$(readlink -f /usr/share/plymouth/themes/default.plymouth)"
echo "plymouth_initrd=$(grep -c 'plymouth/themes/mld/' <<<"$(lsinitrd "/boot/initrd.img-$(uname -r)" 2>/dev/null)")"
echo "kde_pins=$(grep -c 'mld-o365-outlook.desktop' /usr/share/plasma/shells/org.kde.plasma.desktop/contents/updates/mld-pins.js 2>/dev/null)"
echo "plasma_shadow=$( [ -e /usr/local/share/plasma/shells/org.kde.plasma.desktop ] && echo present || echo absent)"
echo "dock_default=$(DCONF_PROFILE=user dconf read /org/gnome/shell/favorite-apps 2>&1)"
echo "desktop_unit=$(systemctl --global is-enabled mld-desktop.service 2>&1)"
echo "ca_ad=$(ls /usr/local/share/ca-certificates/mld/*.crt 2>/dev/null | wc -l)"
echo "ca_chrome=$(python3 -c 'import json, sys; print(len(json.load(open(sys.argv[1]))["CACertificates"]))' /etc/opt/chrome/policies/managed/mld-ca.json 2>&1)"
echo "p11kit_trust=$( [ -e /usr/lib/x86_64-linux-gnu/pkcs11/p11-kit-trust.so ] && echo present || echo absent)"
echo "ca_legacy=$( [ -e /usr/local/share/ca-certificates/mld-ca.crt ] && echo present || echo absent)"
echo "certsrv_tls=$(curl -s -o /dev/null -w '%{http_code}' "https://$(. /etc/mld-cert.conf 2>/dev/null; echo "$DC_FQDN")/certsrv/" 2>&1)"
echo "gpo_chrome=$(grep -ho '"AuthServerAllowlist": *"[^"]*"' /etc/opt/chrome/policies/managed/*.json 2>/dev/null | head -1)"
echo "gpo_firefox=$(python3 -c 'import json, sys; d = json.load(open(sys.argv[1])).get("policies", {}); print(d.get("Authentication", {}).get("SPNEGO"), list(d.get("SecurityDevices", {}).get("Add", {})))' /etc/firefox/policies/policies.json 2>&1)"
echo "gpo_timer=$(systemctl is-enabled mld-gpupdate.timer 2>&1)"
