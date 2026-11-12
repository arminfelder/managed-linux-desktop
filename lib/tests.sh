# Sourced by build.sh: client tests (verify, reboot, fallback, PKI, autoenrollment).
# shellcheck shell=bash

# shellcheck disable=SC2016 # check() evaluates its condition later, so the condition is in single quotes.
client_verify() {
    # A test harness or an older lab.env can lack these: the defaults are the windows values.
    local IDP="${IDP:-windows}" O365_APPS="${O365_APPS:-1}" HOME_MODE="${HOME_MODE:-}"
    [ -n "$HOME_MODE" ] || { if [ "${CIFS_HOME:-1}" = 1 ]; then HOME_MODE=cifs; else HOME_MODE=local; fi; }
    local out fail=0
    out=$(guest_run client client/guest/verify-facts.sh "PROBE_USER=$PROBE_USER" "DC_IP=$DC_IP" \
            "PKI_ENROLL=$PKI_ENROLL" "MACHINE_TOKEN_PIN=$MACHINE_TOKEN_PIN" && client_boot_facts) \
        || { warn "client verify could not query the guest"; return 1; }

    # One line per key. Values can contain "=".
    kv() { printf '%s\n' "$out" | sed -n "s/^$1=//p" | head -1; }
    check() { if eval "$2"; then printf '  ok    %s: %s\n' "$1" "$3"; else printf '  FAIL  %s: %s\n' "$1" "$3"; fail=1; fi; }
    warn_check() { printf '  WARN  %s\n' "$1"; }

    check "Secure Boot"            '[ "$(kv sb)" = "SecureBoot enabled" ]' "$(kv sb)"
    check "LUKS version"           '[ "$(kv luks_version)" = 2 ]' "$(kv luks_version)"
    check "root on dm-crypt"       '[ "$(kv root_on_crypt)" = yes ]' "$(kv root_on_crypt)"
    check "plaintext partitions"   '! printf "%s" "$(kv plain_fs)" | tr " " "\n" | grep -qvE "^(/boot|/boot/efi|)$"' "$(kv plain_fs)"
    check "keyslots (pass + recovery + tokens)" '[ "$(kv keyslots)" -ge 2 ]' "$(kv keyslots)"
    if [ "${ENROLL_TPM2:-0}" = 1 ]; then
        check "TPM2 token"         '[[ " $(kv tokens) " == *" systemd-tpm2 "* ]]' "$(kv tokens)"
        check "crypttab tpm2"      '[[ "$(kv crypttab)" == *tpm2-device=auto* ]]' "$(kv crypttab)"
    fi
    if [ "${UKI:-0}" = 1 ]; then
        check "booted from signed UKI" '[ "$(kv uki_booted)" = yes ]' "$(kv uki_booted), boot entry: $(kv boot_entry)"
        if [ "$UKI_TRUST" = mok ]; then
            check "lab certificate in MOK"      '[ "$(kv mok)" = enrolled ]' "$(kv mok)"
            check "lab certificate not in db"   '[ "$(kv lab_in_db)" = 0 ]' "db entries: $(kv lab_in_db)"
            check "boot entry shim + UKI"       '[ "$(kv boot_entry)" = "MLD UKI (shim) $(kv running)" ]' "$(kv boot_entry)"
        else
            check "lab certificate in db"       '[ "$(kv lab_in_db)" -ge 1 ]' "db entries: $(kv lab_in_db)"
            check "boot entry UKI"              '[ "$(kv boot_entry)" = "MLD UKI $(kv running)" ]' "$(kv boot_entry)"
        fi
        check "one UKI + entry per kernel"  '[ "$(kv uki_files)" = "$(kv kernels)" ] && [ "$(kv uki_entries)" = "$(kv kernels)" ] && [ -z "$(kv uki_legacy)" ]' \
            "kernels: $(kv kernels)| UKIs: $(kv uki_files)| entries: $(kv uki_entries)| old files: $(kv uki_legacy)"
        check "newest kernel first"         '[[ "$(kv boot_first)" == "MLD UKI"*" $(kv kernels | awk "{ print \$NF }")" ]]' "$(kv boot_first)"
    fi
    if [ -n "${FIDO2_HOSTDEV:-}" ]; then
        check "FIDO2 token"        '[[ " $(kv tokens) " == *" systemd-fido2 "* ]]' "$(kv tokens) (run ./build.sh client enroll-fido2 if missing)"
    fi
    if [ "$IDP" = freeipa ]; then
        check "IPA join (host keytab, kinit -k)" '[ -n "$(kv ipa_host_principal)" ] && [ "$(kv ipa_kinit)" = ok ]' \
            "$(kv ipa_host_principal): kinit $(kv ipa_kinit)"
        check "sssd provider ipa" '[ "$(kv ipa_provider)" = ipa ]' "$(kv ipa_provider)"
        check "ticket cache FILE (NFS krb5p)" '[[ "$(kv ipa_ccache)" == FILE:/tmp/krb5cc_* ]]' "$(kv ipa_ccache)"
        if [ "$HOME_MODE" = nfs ]; then check "autofs running" '[ "$(kv autofs)" = active ]' "$(kv autofs)"; fi
    else
        check "Kerberos AES256 (computer account)" '[ "$(kv machine_etype)" = "aes256-cts-hmac-sha1-96, aes256-cts-hmac-sha1-96" ]' \
            "Etype (skey, tkt): $(kv machine_etype)"
        check "AD join (machine account)" '[ "$(kv testjoin)" = "Join is OK" ] && [ "$(kv keytab)" -ge 1 ]' \
            "$(kv testjoin), keytab entries for the computer: $(kv keytab)"
    fi
    check "DNS only to the DC"     '[ -z "$(kv link_dns)" ]' "${DC_IP}$( [ -z "$(kv link_dns)" ] || printf ', also: %s' "$(kv link_dns)")"
    check "local admin has a password" '[[ "$(kv admin_pw)" == *=P || "$(kv admin_pw)" == *=PS ]]' "$(kv admin_pw) (passwd -S: P = password set, NP = none)"
    check "no failed systemd units" '[ -z "$(kv failed_units)" ]' "$(kv failed_units)"
    if [ "$CLIENT_DISTRO" = fedora ]; then
        check "Firefox from Fedora" '[[ "$(kv firefox_pkg)" == "installed "* && "$(kv firefox_vendor)" = "Fedora Project" ]]' \
            "$(kv firefox_pkg), vendor $(kv firefox_vendor)"
        check "SELinux enforcing"  '[ "$(kv selinux)" = Enforcing ]' "$(kv selinux)"
        local avc_note="mld-avc-report"; [ "$(kv avc_unexpected)" != error ] || avc_note="ausearch failed"
        check "no unexpected AVC denials" '[ "$(kv avc_unexpected)" = 0 ]' "$(kv avc_unexpected) ($avc_note)"
        if [ "$HOME_MODE" = nfs ]; then
            check "authselect sssd (no pam_mount, no mkhomedir)" '[[ "$(kv authselect)" == sssd || "$(kv authselect)" == "sssd "* ]] && [[ "$(kv authselect)" != *with-mkhomedir* ]]' "$(kv authselect)"
        elif [ "${CIFS_HOME:-1}" = 1 ] && [ "$IDP" = windows ]; then
            check "authselect custom/mld" '[[ "$(kv authselect)" == custom/mld || "$(kv authselect)" == "custom/mld "* ]]' "$(kv authselect)"
        else
            check "authselect sssd with-mkhomedir" '[[ "$(kv authselect)" == "sssd "*with-mkhomedir* ]]' "$(kv authselect)"
        fi
    else
        check "Firefox from Mozilla"   '[[ "$(kv firefox_pkg)" == "installed "* && "$(kv firefox_origin)" == *packages.mozilla.org* ]]' \
            "$(kv firefox_pkg) $(kv firefox_origin)"
    fi
    if [ "$IDP" = windows ]; then
        check "GPO MLD Linux Clients"  '[[ "$(kv gpo_chrome)" == *"*.${DOMAIN,,}"* && "$(kv gpo_firefox)" == *".${DOMAIN,,}"*p11-kit-trust* ]] && [ "$(kv gpo_timer)" = enabled ]' \
            "Chrome $(kv gpo_chrome); Firefox SPNEGO, SecurityDevices: $(kv gpo_firefox); timer $(kv gpo_timer)"
    else
        check "browser policy from the IPA server" \
            '[[ "$(kv gpo_chrome)" == *"*.${DOMAIN,,}"* && "$(kv gpo_firefox)" == *".${DOMAIN,,}"* ]] &&
             [ "$(kv policy_timer)" = enabled ]' \
            "Chrome $(kv gpo_chrome); Firefox SPNEGO, SecurityDevices: $(kv gpo_firefox); timer $(kv policy_timer)"
        check "IPA CA in the Chrome policy"  '[[ "$(kv ca_chrome)" =~ ^[1-9][0-9]*$ ]]' "$(kv ca_chrome) CA in mld-ca.json"
    fi
    check "Chrome installed"       '[[ "$(kv chrome_pkg)" == "installed "* ]]' "$(kv chrome_pkg)"
    check "Chrome: no default-browser prompt, no telemetry" \
        '[[ " $(kv chrome_policy) " == *" DefaultBrowserSettingEnabled "* && " $(kv chrome_policy) " == *" MetricsReportingEnabled "* ]]' \
        "off: $(kv chrome_policy)"
    local o365_n=7; [ "$O365_APPS" = 1 ] || o365_n=0
    check "O365 launchers + icons (O365_APPS=$O365_APPS)"  '[ "$(kv o365_launchers)" = "$o365_n" ] && [ "$(kv o365_icons)" = "$o365_n" ] && [ "$(kv o365_policy)" = absent ]' \
        "$(kv o365_launchers) launchers, $(kv o365_icons) icons, old web app policy $(kv o365_policy)"
    local dm=$CLIENT_DM_UNIT
    check "desktop $CLIENT_DE (display manager $dm)" '[ "$(kv de_installed)" = "$CLIENT_DE" ] && [ "$(kv dm_unit)" = "$dm/active" ]' \
        "installed: $(kv de_installed), display-manager: $(kv dm_unit)"
    if [ "$CLIENT_DE" = kde ]; then
        check "task manager pins (Plasma update script)" '[ "$(kv kde_pins)" = "$O365_APPS" ]' "mld-pins.js: $(kv kde_pins) Outlook pin"
        check "Plasma shell package not shadowed" '[ "$(kv plasma_shadow)" = absent ]' \
            "/usr/local/share/plasma/shells/org.kde.plasma.desktop $(kv plasma_shadow)"
        if [ "$CLIENT_DISTRO" = fedora ]; then
            check "plasma-login-manager running" '[ "$(kv greeter_unit)" = active ]' "$dm: $(kv greeter_unit)"
            check "plasma-login-manager drop-in (MLD background)" '[ "$(kv greeter_dropin)" = present ]' "/etc/plasmalogin.conf.d/90-mld.conf $(kv greeter_dropin)"
            warn_check "AD user login on the Fedora KDE greeter: manual check (no user-list setting found in plasma-login-manager; see spec Probe results item 2)"
        else
            check "SDDM asks for the user name (no user list)" '[ "$(kv sddm_userlist)" = 999 ]' "MaximumUid=$(kv sddm_userlist)"
            check "SDDM theme Breeze, MLD background" '[ "$(kv sddm_theme)" = breeze ] && [ "$(kv sddm_bg)" = /usr/share/mld/brand/background.png ]' \
                "theme $(kv sddm_theme), background $(kv sddm_bg)"
        fi
    else
        local ffpin="'firefox.desktop'"
        [ "$CLIENT_DISTRO" != fedora ] || ffpin="'org.mozilla.firefox.desktop'"
        check "dock pins (dconf default)" '{ [ "$O365_APPS" != 1 ] || [[ "$(kv dock_default)" == *mld-o365-outlook.desktop* ]]; } && [[ "$(kv dock_default)" == *google-chrome.desktop* && "$(kv dock_default)" == *"$ffpin"* ]]' \
            "$(kv dock_default)"
    fi
    if [ "$CLIENT_DISTRO" = fedora ]; then
        check "automatic updates (dnf5-automatic)" '[[ "$(kv upd_pkg)" == "installed "* && "$(kv upd_timer)" == "enabled enabled " && "$(kv upd_conf)" = yes && "$(kv upd_conf_deprecated)" = absent && "$(kv upd_dropin)" = present ]]' \
            "$(kv upd_pkg), timers dnf5-automatic mld-reboot: $(kv upd_timer), apply_updates=$(kv upd_conf) (/etc/dnf/automatic.conf), /etc/dnf/dnf5-plugins/automatic.conf $(kv upd_conf_deprecated), drop-in $(kv upd_dropin)"
        check "update sources (enabled repos)" 'r=" $(kv upd_repos)"; [[ "$r" == *" fedora "* && "$r" == *" updates "* && "$r" == *" google-chrome "* ]] && { [ "${SNX_RS:-1}" != 1 ] || [[ "$r" == *" snx-rs "* ]]; }' \
            "$(kv upd_repos)"
    else
        check "automatic updates"      '[[ "$(kv uu_pkg)" == "installed "* && "$(kv uu_periodic)" == "1 1 " && "$(kv uu_timers)" == "enabled enabled enabled " ]]' \
            "$(kv uu_pkg), periodic lists+upgrade: $(kv uu_periodic), timers apt-daily apt-daily-upgrade mld-reboot: $(kv uu_timers)"
        check "update sources"         'o=$(kv uu_origins); [[ "$o" == *-security* && "$o" == *-updates* && "$o" == *site=packages.mozilla.org* && "$o" == *site=dl.google.com* && "$o" == *site=ancwrd1.github.io* ]]' \
            "$(kv uu_origins)"
    fi
    local ply=/usr/share/plymouth/themes/mld/mld.plymouth
    [ "$CLIENT_DISTRO" != fedora ] || ply=mld
    check "Plymouth theme mld"     '[ "$(kv plymouth_theme)" = "$ply" ] && [ "$(kv plymouth_initrd)" -ge 2 ]' \
        "default $(kv plymouth_theme), files in the initrd: $(kv plymouth_initrd)"
    if [ "$CLIENT_DISTRO" = fedora ] && [ "$CLIENT_DE" = gnome ]; then
        check "no desktop user unit (stock Fedora GNOME)" '[ "$(kv desktop_unit)" = disabled ]' "$(kv desktop_unit)"
    else
        check "desktop user unit"      '[ "$(kv desktop_unit)" = enabled ]' "$(kv desktop_unit)"
    fi
    if [ "${SNX_RS:-1}" = 1 ]; then
        check "snx-rs installed"   '[[ "$(kv snx_pkg)" == "installed "* ]]' "$(kv snx_pkg)"
        check "snx-rs service"     '[ "$(kv snx_active)" = active ]' "$(kv snx_active)"
        check "snx-rs GUI in the app menu" '[ "$(kv snx_menu)" = present ]' "$(kv snx_menu)"
        check "snx-rs TPM store"   '[[ "$(kv snx_dropin)" == *TPM2_PKCS11_STORE=/etc/tpm2_pkcs11* ]]' "$(kv snx_dropin)"
    else
        check "snx-rs not installed (SNX_RS=0)" '[[ "$(kv snx_pkg)" != "installed "* ]]' "$(kv snx_pkg | grep . || echo absent)"
    fi
    check "AD user resolves"       '[[ "$(kv probe_id)" == *"${LINUX_GROUP,,}"* ]]' "$(kv probe_id)"
    check "recovery key in guest"  '[ "$(kv recovery)" = present ] || [ -s "$STAGE/recovery-key" ]' "$(kv recovery)"

    if [ "$(kv recovery)" = present ]; then
        ( umask 077; ./guest-exec.sh client 'cat /var/lib/mld/recovery-key' > "$STAGE/recovery-key" ) \
            && ./guest-exec.sh client 'shred -u /var/lib/mld/recovery-key' \
            && log "recovery key moved to .stage/recovery-key (not in the guest any more)"
    fi

    client_verify_login || fail=1
    client_verify_browsers || fail=1
    if [ "${PKI_ENROLL:-none}" != none ] && [ "${IDP:-windows}" = freeipa ]; then
        local ae
        ae=$(./guest-exec.sh client 'mld-autoenroll status' 2>&1)
        check "machine certificate from the IPA CA (certmonger)" \
            '[[ "$ae" == *"mld-ipa-machine"* && "$ae" == *"status: MONITORING"* &&
                "$ae" == *"token='"'"'mld-machine'"'"'"* ]]' \
            "$(grep -E "status:|issuer:|expires:" <<<"$ae" | tr -s ' \n' ' ')"
        check "machine cert over PKCS#11 (MACHINE_TOKEN_PIN)" '[ "$(kv machine_p11_certs)" = 1 ]' \
            "$(kv machine_p11_certs) certificate(s), ID $(kv machine_p11_id)"
        check "machine key signs (no prompt)" '[ "$(kv machine_p11_sign)" -gt 0 ]' "$(kv machine_p11_sign) bytes"
    elif [ "${PKI_ENROLL:-none}" != none ]; then
        local ae
        ae=$(./guest-exec.sh client 'mld-autoenroll status' 2>&1)
        check "autoenrolled MLD-LinuxComputer (certmonger)" \
            '[[ "$ae" == *"mld-MLD-LinuxComputer"* && "$ae" == *"status: MONITORING"* ]]' \
            "$(grep -E "status:|expires:" <<<"$ae" | tr -s ' \n' ' ')"
        check "AD CA certificates trusted" '[ "$(kv ca_ad)" -ge 1 ] && [ "$(kv ca_chrome)" = "$(kv ca_ad)" ] && [ "$(kv ca_legacy)" = absent ] && [ "$(kv certsrv_tls)" = 401 ] && [ "$(kv p11kit_trust)" = present ]' \
            "$(kv ca_ad) in the system store, $(kv ca_chrome) in the Chrome policy, curl certsrv without -k: HTTP $(kv certsrv_tls), p11-kit-trust for Firefox: $(kv p11kit_trust)"
        check "machine cert over PKCS#11 (MACHINE_TOKEN_PIN)" '[ "$(kv machine_p11_certs)" = 1 ]' \
            "$(kv machine_p11_certs) certificate(s), ID $(kv machine_p11_id)"
        check "machine key signs (no prompt)" '[ "$(kv machine_p11_sign)" -gt 0 ]' "$(kv machine_p11_sign) bytes"
        check "autoenroll key in the TPM token" '[[ "$ae" == *"token='"'"'mld-machine'"'"'"* ]]' \
            "$(grep -o "token='[^']*'" <<<"$ae" | head -1)"
    fi
    return "$fail"
}

# AD password login over ssh: pam_sss gets the TGT, pam_mount mounts Homes$/<user> with sec=krb5.
# The DC then reads the probe file from C:\Homes, so the write went over CIFS to the DC.
client_verify_login() {
    # A test harness or an older lab.env can lack these: the defaults are the windows values.
    local IDP="${IDP:-windows}" O365_APPS="${O365_APPS:-1}" HOME_MODE="${HOME_MODE:-}"
    [ -n "$HOME_MODE" ] || { if [ "${CIFS_HOME:-1}" = 1 ]; then HOME_MODE=cifs; else HOME_MODE=local; fi; }
    command -v sshpass >/dev/null 2>&1 || { warn "sshpass missing: login + CIFS test skipped"; return 1; }
    need_secrets LAB_USER_PW
    local token out got
    token="probe-$(date -u +%s)"
    # Desktop folder (mld-desktop user unit): local, with the trusted launchers for Desktop Icons NG.
    local desk='systemctl --user start mld-desktop.service; d=$(xdg-user-dir DESKTOP); echo desk=$d; echo desk_n=$(ls "$d" | grep -c "^mld-o365-.*\.desktop$"); echo desk_trusted=$(gio info -a metadata::trusted "$d/mld-o365-outlook.desktop" | grep -c "trusted: true"); echo desk_mode=$(stat -c %a "$d/mld-o365-outlook.desktop"); echo desk_snx=$(stat -c %a "$d/snx-rs-gui.desktop" 2>/dev/null)'
    if [ "$CLIENT_DISTRO" = fedora ] && [ "$CLIENT_DE" = gnome ]; then desk=; fi
    out=$(SSHPASS="$LAB_USER_PW" SSH_ASKPASS_REQUIRE=never sshpass -e ssh -o NumberOfPasswordPrompts=1 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o PreferredAuthentications=password,keyboard-interactive -o LogLevel=ERROR \
            "$PROBE_USER@$CLIENT_IP" \
            "echo fs=\$(findmnt -no FSTYPE,SOURCE -T \"\$HOME\"); echo nfs_sec=\$(findmnt -no OPTIONS -T \"\$HOME\" | tr , '\n' | sed -n 's/^sec=//p'); klist -s && echo tgt=yes || echo tgt=no; echo $token > \"\$HOME/mld-probe\"; $desk" 2>&1) \
        || { printf '  FAIL  ssh login as %s: %s\n' "$PROBE_USER" "$out"; return 1; }
    printf '  ok    ssh login as %s\n' "$PROBE_USER"
    local dn dd fail_desk=0
    dd=$(sed -n 's/^desk=//p' <<<"$out"); dn=$(sed -n 's/^desk_n=//p' <<<"$out")
    local want_trusted=1; [ "$CLIENT_DE" = kde ] && want_trusted=0
    if [ "$CLIENT_DISTRO" = fedora ] && [ "$CLIENT_DE" = gnome ]; then
        printf '  ok    desktop icons: not used (stock Fedora GNOME, launchers in the app grid)\n'
    elif [ "$O365_APPS" != 1 ] && [[ "$dd" == /var/lib/mld-users/* ]] && [ "$dn" = 0 ]; then
        printf '  ok    desktop icons: %s, no Microsoft 365 launchers (O365_APPS=0)\n' "$dd"
    elif [[ "$dd" == /var/lib/mld-users/* ]] && [ "$dn" = 7 ] && grep -qx 'desk_mode=755' <<<"$out" \
        && { [ "$want_trusted" = 0 ] || grep -qx 'desk_trusted=1' <<<"$out"; }; then
        printf '  ok    desktop icons: %s, %s launchers, 755%s\n' "$dd" "$dn" "$([ "$want_trusted" = 1 ] && echo ', trusted')"
    else printf '  FAIL  desktop icons: %s\n' "$(grep '^desk' <<<"$out" | tr '\n' ' ')"; fail_desk=1; fi
    if [ "${SNX_RS:-1}" = 1 ] && ! { [ "$CLIENT_DISTRO" = fedora ] && [ "$CLIENT_DE" = gnome ]; }; then
        if grep -qx 'desk_snx=755' <<<"$out"; then printf '  ok    snx-rs GUI on the desktop\n'
        else printf '  FAIL  snx-rs GUI on the desktop: %s\n' "$(grep '^desk_snx' <<<"$out")"; fail_desk=1; fi
    fi
    if printf '%s' "$out" | grep -q 'tgt=yes'; then printf '  ok    Kerberos TGT in the session\n'
    else printf '  FAIL  no Kerberos TGT in the session\n'; return 1; fi
    if [ "$HOME_MODE" = local ]; then
        if grep -qE '^fs=(cifs|nfs4)' <<<"$out"; then printf '  FAIL  home is on the network, the lab wants a local home\n'; return 1; fi
        printf '  ok    local home: %s\n' "$(sed -n 's/^fs=//p' <<<"$out")"
        return "$fail_desk"
    fi
    local want_fs=cifs; [ "$HOME_MODE" != nfs ] || want_fs=nfs4
    if grep -q "^fs=$want_fs " <<<"$out"; then printf '  ok    home on %s: %s\n' "$want_fs" "$(sed -n 's/^fs=//p' <<<"$out")"
    else printf '  FAIL  home is not on %s: %s\n' "$want_fs" "$out"; return 1; fi
    if [ "$HOME_MODE" = nfs ]; then
        if grep -qx 'nfs_sec=krb5p' <<<"$out"; then printf '  ok    NFS home with sec=krb5p\n'
        else printf '  FAIL  NFS home is not sec=krb5p: %s\n' "$(grep '^nfs_sec' <<<"$out")"; return 1; fi
    fi
    got=$(dc_read_home_file "$PROBE_USER" mld-probe | tr -d '\r\n')
    if [ "$got" = "$token" ]; then printf '  ok    DC sees the file written on the client (%s)\n' "$token"
    else printf '  FAIL  DC read "%s", want "%s"\n' "$got" "$token"; return 1; fi
    return "$fail_desk"
}

# Firefox and Chrome as the AD user: TLS to certsrv with the AD CA, then Kerberos through the GPO allowlist.
client_verify_browsers() {
    # A test harness or an older lab.env can lack these: the defaults are the windows values.
    local IDP="${IDP:-windows}" O365_APPS="${O365_APPS:-1}" HOME_MODE="${HOME_MODE:-}"
    [ -n "$HOME_MODE" ] || { if [ "${CIFS_HOME:-1}" = 1 ]; then HOME_MODE=cifs; else HOME_MODE=local; fi; }
    command -v sshpass >/dev/null 2>&1 || { warn "sshpass missing: browser test skipped"; return 1; }
    need_secrets LAB_USER_PW
    # IDP=freeipa has no certsrv: the policy endpoint also needs TLS (IPA CA) and Kerberos.
    local out b rc=0 url="https://$DC_FQDN/certsrv/" ca=AD
    if [ "$IDP" = freeipa ]; then url="https://$DC_FQDN/mld-policy/manifest" ca=IPA; fi
    out=$( { printf 'DC_FQDN=%q\nPROBE_URL=%q\n' "$DC_FQDN" "$url"; cat client/guest/browser-kerberos.sh; } \
        | SSHPASS="$LAB_USER_PW" SSH_ASKPASS_REQUIRE=never sshpass -e ssh -o NumberOfPasswordPrompts=1 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o PreferredAuthentications=password,keyboard-interactive -o LogLevel=ERROR \
            "$PROBE_USER@$CLIENT_IP" bash -s 2>&1) || { printf '  FAIL  browser test: %s\n' "$out"; return 1; }
    for b in chrome firefox; do
        if grep -qx "${b}_http_before=0" <<<"$out" && grep -qx "${b}_http_ticket=[1-9][0-9]*" <<<"$out"; then
            printf '  ok    %s: TLS with the %s CA + Kerberos to %s\n' "$b" "$ca" "$DC_FQDN"
        elif [ "$b" = chrome ]; then
            # Known issue (README "Known limits"): Chrome 157 answers Negotiate with ERR_UNSUPPORTED_AUTH_SCHEME.
            printf '  open  %s: no Kerberos (known issue): %s\n' "$b" "$(grep "^${b}_" <<<"$out" | tr '\n' ' ')"
        else
            printf '  FAIL  %s: no HTTP/%s ticket (%s)\n' "$b" "$DC_FQDN" "$(grep "^${b}_" <<<"$out" | tr '\n' ' ')"; rc=1
        fi
    done
    return "$rc"
}

client_reboot_test() {
    if [ "${ENROLL_TPM2:-0}" != 1 ] && [ -z "${FIDO2_HOSTDEV:-}" ]; then
        die "no TPM2 and no FIDO2 configured: every boot asks for the passphrase (use client start)"
    fi
    [ -z "${FIDO2_HOSTDEV:-}" ] || warn "FIDO2: touch the key when it blinks"
    log "rebooting $CLIENT_VM; the boot must not ask for the passphrase"
    if client_reboot_console expect-no-prompt; then
        log "unlocked without the passphrase"
    else
        warn "a passphrase prompt appeared or no login prompt came. Read .stage/client-console.log"
        warn "the VM waits at the prompt now: ./build.sh client unlock"
        return 1
    fi
}

# Boots the plain shim + grub entry once (BootNext). PCR 7 differs from the UKI path, so TPM2 must refuse.
client_fallback_test() {
    [ "${UKI:-0}" = 1 ] && [ "${ENROLL_TPM2:-0}" = 1 ] || die "client fallback-test needs UKI=1 and ENROLL_TPM2=1"
    need_secrets LUKS_PASSPHRASE
    local n facts
    n=$(guest_run client client/guest/grub-entry.sh) || die "cannot read the boot entries"
    [ -n "$n" ] || die "no shim + grub boot entry (boot label matching the distro) found"
    ./guest-exec.sh client "efibootmgr --quiet --bootnext $n" || die "efibootmgr --bootnext $n failed"
    log "rebooting once through Boot$n (shim + grub): the passphrase prompt must appear"
    if ! client_reboot_console expect-prompt; then
        warn "no passphrase prompt on the shim + grub path, or no login. Read .stage/client-console.log"
        return 1
    fi
    facts=$(client_boot_facts) || die "cannot query the guest"
    grep -qx 'uki_booted=no' <<<"$facts" || { warn "the boot came from the UKI, not from grub: $(tr '\n' ' ' <<<"$facts")"; return 1; }
    log "TPM2 refused on the shim + grub path, passphrase unlocked ($(tr '\n' ' ' <<<"$facts"))"
}

# Prints ok/FAIL lines for the output of "mld-cert check".
pki_report() {
    local who="$1" how="$2" out="$3" fail=0 k
    for k in key=tpm match=yes tpm_sign=yes chain=yes; do
        if grep -qx "$k" <<<"$out"; then :; else fail=1; fi
    done
    if [ "$fail" = 0 ]; then
        printf '  ok    %s certificate via %s: TPM key, matches, TPM signs, chain ok (%s)\n' "$who" "$how" \
            "$(sed -n 's/^subject=//p' <<<"$out" | tail -1)"
    else
        printf '  FAIL  %s certificate via %s: %s\n' "$who" "$how" "$(tr '\n' ' ' <<<"$out")"
    fi
    return "$fail"
}

# Both enrollment paths (certsrv web, DCOM) for the machine and for the probe user.
client_pki_test() {
    local how out fail=0
    for how in web dcom; do
        out=$(./guest-exec.sh client "mld-cert machine $how >&2 && mld-cert check machine" 2>&1) || true
        pki_report machine "$how" "$out" || fail=1
        out=$(client_ssh_user "mld-cert user $how >&2 && mld-cert check user" 2>&1) || true
        pki_report "user $PROBE_USER" "$how" "$out" || fail=1
    done
    return "$fail"
}

# Autoenrollment as on Windows: machine (certmonger status) and the probe user (session certmonger, own TPM token).
client_autoenroll_test() {
    # Optional web|dcom: switch the certmonger CAs to this path and renew both certificates through it.
    local how="${1:-}" out fail=0 mod=":" umod=":" mtok=mld-machine utok=mld-user
    if [ "${IDP:-windows}" = freeipa ]; then
        # IDP=freeipa: one CA path. "renew" gets new certificates for the two existing keys.
        [[ "$how" =~ ^(|renew)$ ]] || die "usage: client autoenroll-test [renew] (IDP=freeipa)"
        if [ "$how" = renew ]; then
            mod="getcert resubmit -i mld-ipa-machine -w >/dev/null"
            umod="getcert resubmit -s -i mld-ipa-user -w >/dev/null"
        fi
    elif [ -n "$how" ]; then
        [[ "$how" =~ ^(web|dcom)$ ]] || die "usage: client autoenroll-test [web|dcom]"
        mod="getcert modify-ca -c MLD-AD-machine -e '/usr/local/libexec/mld-cm-submit machine $how' >/dev/null && getcert resubmit -i mld-MLD-LinuxComputer -w >/dev/null"
        umod="getcert modify-ca -s -c MLD-AD-user -e '/usr/local/libexec/mld-cm-submit user $how' >/dev/null && getcert resubmit -s -i mld-MLD-LinuxUser -w >/dev/null"
    fi
    out=$(./guest-exec.sh client "$mod; mld-autoenroll status" 2>&1)
    if [[ "$out" == *"status: MONITORING"* && "$out" == *"token='$mtok'"* ]]; then
        printf '  ok    machine%s: %s\n' "${how:+ via $how}" "$(grep -E "Request ID|expires" <<<"$out" | tr -s ' \n\t' ' ')"
    else printf '  FAIL  machine%s: %s\n' "${how:+ via $how}" "$(tr '\n' ' ' <<<"$out")"; fail=1; fi
    out=$(client_ssh_user "systemctl --user start mld-certmonger-user.service && mld-autoenroll setup user && mld-autoenroll user && $umod; mld-autoenroll status user" 2>&1) || true
    if [[ "$out" == *"status: MONITORING"* && "$out" == *"token='$utok'"* ]]; then
        printf '  ok    user %s%s: %s\n' "$PROBE_USER" "${how:+ via $how}" "$(grep -E "yes |Request ID|expires" <<<"$out" | tr -s ' \n\t' ' ')"
    else printf '  FAIL  user %s%s: %s\n' "$PROBE_USER" "${how:+ via $how}" "$(tr '\n' ' ' <<<"$out")"; fail=1; fi
    client_token_certs_test || fail=1
    return "$fail"
}

# Exactly one certificate per TPM token, also after a renewal (post-save mld-cert-prune).
# The post-save command runs after "getcert resubmit -w" returns: wait up to 30 s.
client_token_certs_test() {
    local n fail=0 who cmd
    local count='m=$(ls /usr/lib64/pkcs11/libtpm2_pkcs11.so /usr/lib/x86_64-linux-gnu/pkcs11/libtpm2_pkcs11.so \
    2>/dev/null | head -1)
for _ in $(seq 1 15); do
    n=$(TSS2_LOG=all+NONE pkcs11-tool --module "$m" --token-label TOKEN --list-objects --type cert 2>/dev/null \
        | grep -c "Certificate Object")
    [ "$n" != 1 ] || break; sleep 2
done; echo "$n"'
    for who in machine user; do
        cmd=${count/TOKEN/mld-$who}
        if [ "$who" = machine ]; then n=$(./guest-exec.sh client "$cmd" 2>&1 | tail -1)
        else n=$(client_ssh_user "$cmd" 2>&1 | tail -1); fi
        if [ "$n" = 1 ]; then printf '  ok    token mld-%s: 1 certificate\n' "$who"
        else printf '  FAIL  token mld-%s: %s certificates (want 1)\n' "$who" "$n"; fail=1; fi
    done
    return "$fail"
}
