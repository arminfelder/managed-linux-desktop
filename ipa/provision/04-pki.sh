# shellcheck shell=bash
# Phase 4: user certificate profile and CA ACL. Machine certificates use the stock ACL hosts_services_caIPAserviceCert.
# Sourced by run.sh.
ipa_kinit
if ! ipa certprofile-show mldUserCert >/dev/null 2>&1; then
    ipa certprofile-show caIPAserviceCert --out "$STATE/caIPAserviceCert.cfg" >/dev/null
    sed -e 's/^profileId=.*/profileId=mldUserCert/' -e 's/^name=.*/name=MLD user certificate/' \
        -e 's/^desc=.*/desc=MLD user certificate/' "$STATE/caIPAserviceCert.cfg" > "$STATE/mldUserCert.cfg"
    ipa certprofile-import mldUserCert --file "$STATE/mldUserCert.cfg" --desc "MLD user certificate" \
        --store=true >/dev/null
    log "profile mldUserCert imported"
fi
ipa_q caacl-add mld-users
ipa_q caacl-add-profile mld-users --certprofiles=mldUserCert
ipa_q caacl-add-user mld-users --groups="$IDM_GROUP"
ipa_q caacl-add-ca mld-users --cas=ipa
