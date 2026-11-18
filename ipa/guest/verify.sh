# shellcheck shell=bash
# Runs on the IPA server as root (build.sh guest_run, variables ADMIN_PW DOMAIN DC_FQDN LAB_USERS IDM_GROUP).
# Prints one JSON line for dc verify. Each value is a fact, the checks are in lib/ipa.sh.
export KRB5CCNAME=FILE:/var/lib/mld-ipa/verify.cc
printf '%s' "$ADMIN_PW" | kinit admin >/dev/null 2>&1
q() { "$@" >/dev/null 2>&1 && echo true || echo false; }
srv() { dig +short @127.0.0.1 "$1" SRV | grep -c . || true; }
users=""
for u in $LAB_USERS; do
    exp=$(ipa user-show "$u" --all --raw 2>/dev/null | sed -n 's/^ *krbpasswordexpiration: *//Ip')
    member=$(ipa group-show "$IDM_GROUP" --raw 2>/dev/null | grep -c "uid=$u," || true)
    home=$(stat -c '%U %a' "/export/home/$u" 2>/dev/null)
    users+="{\"name\":\"$u\",\"expiration\":\"$exp\",\"member\":$member,\"home\":\"$home\"},"
done
admin_exp=$(ipa user-show admin --all --raw 2>/dev/null | sed -n 's/^ *krbpasswordexpiration: *//Ip')
running=$(ipactl status 2>/dev/null | grep -c 'RUNNING$' || true)
stopped=$(ipactl status 2>/dev/null | grep -c 'STOPPED$' || true)
allow_all=$(ipa hbacrule-show allow_all --raw 2>/dev/null | sed -n 's/^ *ipaenabledflag: *//p')
mld_hbac=$(ipa hbacrule-show mld-linux-login --raw 2>/dev/null | sed -n 's/^ *ipaenabledflag: *//p')
policy=$(curl -s -o /dev/null -w '%{http_code}' --cacert /etc/ipa/ca.crt "https://$DC_FQDN/mld-policy/manifest")
printf '{"running":%s,"stopped":%s,"srv_ldap":%s,"srv_kerberos":%s,"allow_all":"%s","mld_hbac":"%s",' \
    "$running" "$stopped" "$(srv "_ldap._tcp.$DOMAIN")" "$(srv "_kerberos._udp.$DOMAIN")" "$allow_all" "$mld_hbac"
printf '"admin_expiration":"%s","export":%s,"nfs_keytab":%s,"automount":%s,"profile":%s,"caacl":%s,"policy":"%s",' \
    "$admin_exp" "$(q grep -q 'sec=krb5p' /etc/exports)" \
    "$(q sh -c "klist -k /etc/krb5.keytab | grep -q ' nfs/$DC_FQDN@'")" \
    "$(q ipa automountkey-show default auto.home --key='*')" "$(q ipa certprofile-show mldUserCert)" \
    "$(q ipa caacl-show mld-users)" "$policy"
printf '"nfs_units":"%s",' "$(systemctl is-active nfs-server nfs-mountd | tr '\n' ' ')"
printf '"users":[%s]}\n' "${users%,}"
kdestroy >/dev/null 2>&1 || true
