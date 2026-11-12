# shellcheck shell=bash
# Phase 3: NFSv4 homes (sec=krb5p) and the automount maps. Sourced by run.sh.
ipa_kinit
install -d -m 755 /export/home
for u in $LAB_USERS; do
    install -d -m 700 -o "$u" -g "$u" "/export/home/$u"
done
printf '/export/home *(rw,sec=krb5p,root_squash)\n' > /etc/exports
ipa_q service-add "nfs/$DC_FQDN"
# A new key makes the service tickets of the clients invalid: get it only once.
klist -k /etc/krb5.keytab | grep -q " nfs/$DC_FQDN@" || ipa-getkeytab -p "nfs/$DC_FQDN" -k /etc/krb5.keytab >/dev/null
# rpc.mountd stops at start when /var/lib/nfs/etab is missing, and nfsd then drops every request (seen 2026-11-18).
exportfs -ra
systemctl enable --now nfs-server
systemctl is-active --quiet nfs-mountd || { echo "nfs-mountd is not active after the nfs-server start" >&2; false; }
ipa_q automountmap-add default auto.home
ipa_q automountkey-add default auto.master --key=/home/mld --info=auto.home
ipa_q automountkey-add default auto.home --key='*' --info="-fstype=nfs4,sec=krb5p,rw $DC_FQDN:/export/home/&"
