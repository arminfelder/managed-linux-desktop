# shellcheck shell=bash
# Phase 2: users, group, host group, HBAC. Sourced by run.sh.
ipa_kinit
# IPA sets a password that an admin gives as expired. The lab passwords must work at the first login.
far=$(date -u -d '+10 years' +%Y%m%d%H%M%SZ)
ipa_q user-mod admin --password-expiration="$far"
ipa_q config-mod --homedirectory=/home/mld
ipa_q group-add "$IDM_GROUP" --desc "MLD Linux users"
for u in $LAB_USERS; do
    if ! ipa user-show "$u" >/dev/null 2>&1; then
        printf '%s\n%s\n' "$LAB_USER_PW" "$LAB_USER_PW" \
            | ipa user-add "$u" --first "$u" --last Lab --homedir "/home/mld/$u" --password >/dev/null
        log "user $u added"
    fi
    ipa_q user-mod "$u" --password-expiration="$far"
    ipa_q group-add-member "$IDM_GROUP" --users="$u"
done
# build.sh adds each client to this host group (ipa/guest/host-add.sh).
ipa_q hostgroup-add linux-clients --desc "MLD Linux clients"
ipa_q hbacrule-add mld-linux-login --servicecat=all
ipa_q hbacrule-add-user mld-linux-login --groups="$IDM_GROUP"
ipa_q hbacrule-add-host mld-linux-login --hostgroups=linux-clients
ipa_q hbacrule-disable allow_all
