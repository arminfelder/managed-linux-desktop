# shellcheck shell=bash
# Phase 5: the policy endpoint https://<server>/mld-policy/ (Kerberos only). The clients pull their policy files there.
# Sourced by run.sh. The sources are $LIB/policy/*.json (repo ipa/policy). ./build.sh dc policy pushes them again
# and runs this phase only.
install -d -m 755 "$STATE/policy"
# manifest: one "sha256  name" line per file (sha256sum format). The client maps each name to a fixed target path.
tmp=$(mktemp -d)
names=()
for f in "$LIB"/policy/*.json; do
    if [ -e "$f" ]; then
        sed "s/@@DOMAIN@@/${DOMAIN,,}/g" "$f" > "$tmp/${f##*/}"
        names+=("${f##*/}")
    fi
done
: > "$tmp/manifest"
if [ "${#names[@]}" -gt 0 ]; then
    ( cd "$tmp" && sha256sum "${names[@]}" ) > "$tmp/manifest"
    install -m 644 "${names[@]/#/$tmp/}" "$STATE/policy/"
fi
# The manifest goes last: a client that reads it during the update finds the new files.
install -m 644 "$tmp/manifest" "$STATE/policy/manifest"
for f in "$STATE"/policy/*.json; do
    if [ -e "$f" ] && [ ! -e "$tmp/${f##*/}" ]; then rm -f "$f"; fi
done
rm -rf "$tmp"
log "policy files: $(awk '{ printf "%s ", $2 }' "$STATE/policy/manifest")"
# No GssapiCredStore: the IPA httpd gets its keys through gssproxy (GSS_USE_PROXY).
cat > /etc/httpd/conf.d/mld-policy.conf <<EOF
Alias /mld-policy $STATE/policy
<Directory $STATE/policy>
  AuthType GSSAPI
  AuthName "MLD policy"
  GssapiAllowedMech krb5
  GssapiUseSessions Off
  Require valid-user
  Options None
  AllowOverride None
</Directory>
EOF
semanage fcontext -l | grep -qF "$STATE/policy(/.*)?" \
    || semanage fcontext -a -t httpd_sys_content_t "$STATE/policy(/.*)?"
restorecon -R "$STATE/policy"
systemctl reload httpd
