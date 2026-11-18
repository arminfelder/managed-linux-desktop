# Sourced by build.sh: values derived from lab.env, defaults, checks, template rendering.
# shellcheck shell=bash

REALM=${DOMAIN^^}
DC_FQDN=$(printf '%s.%s' "$DC_HOSTNAME" "$DOMAIN" | tr '[:upper:]' '[:lower:]')
DOMAIN_DN=$(printf 'DC=%s' "${DOMAIN//./,DC=}")
LINUX_OU="OU=Computers,OU=Linux,$DOMAIN_DN"
LINUX_GROUPS_OU="OU=Groups,OU=Linux,$DOMAIN_DN"
IFS=. read -r _o1 _o2 _o3 _ <<<"$DC_IP"
# shellcheck disable=SC2034 # used in lib/host.sh (cmd_net) and lib/dc.sh (config.ps1)
NETWORK_ID="$_o1.$_o2.$_o3.0/$NET_PREFIX"
# shellcheck disable=SC2034 # used in lib/dc.sh (config.ps1)
REVERSE_ZONE="$_o3.$_o2.$_o1.in-addr.arpa"
[ "$NET_PREFIX" = 24 ] || die "NET_PREFIX must be 24 (reverse zone and DHCP range assume a /24)"
DHCP_START="$_o1.$_o2.$_o3.100"
DHCP_END="$_o1.$_o2.$_o3.254"
read -ra LAB_USER_LIST <<<"$LAB_USERS"
PROBE_USER="${LAB_USER_LIST[0]}"
SMB_SEAL=$([ "${SMB_ENCRYPT:-1}" = 1 ] && echo ',seal' || true)
# Defaults for values that an older lab.env does not have.
CA_NAME="${CA_NAME:-MLD-Lab-CA}"
IDP="${IDP:-windows}"
[[ "$IDP" =~ ^(windows|freeipa)$ ]] || die "IDP must be windows or freeipa, not '$IDP'"
CIFS_HOME="${CIFS_HOME:-1}"
NFS_HOME="${NFS_HOME:-1}"
if [ "$IDP" = freeipa ]; then
    PKI_ENROLL="${PKI_ENROLL:-ipa}" PKI_ENROLL="${PKI_ENROLL,,}"
    [[ "$PKI_ENROLL" =~ ^(ipa|none)$ ]] || die "IDP=freeipa: PKI_ENROLL must be ipa or none, not '$PKI_ENROLL'"
    [[ "$NFS_HOME" =~ ^[01]$ ]] || die "NFS_HOME must be 0 or 1, not '$NFS_HOME'"
    HOME_MODE=$([ "$NFS_HOME" = 1 ] && echo nfs || echo local)
    O365_APPS="${O365_APPS:-0}"
    # FreeIPA keeps group names in lower case. The sssd ipa provider compares names case-sensitively.
    IDM_GROUP="${LINUX_GROUP,,}"
else
    PKI_ENROLL="${PKI_ENROLL:-web}" PKI_ENROLL="${PKI_ENROLL,,}"
    [[ "$PKI_ENROLL" =~ ^(web|dcom|none)$ ]] || die "PKI_ENROLL must be web, dcom or none, not '$PKI_ENROLL'"
    HOME_MODE=$([ "$CIFS_HOME" = 1 ] && echo cifs || echo local)
    O365_APPS="${O365_APPS:-1}"
    IDM_GROUP="$LINUX_GROUP"
fi
[[ "$O365_APPS" =~ ^[01]$ ]] || die "O365_APPS must be 0 or 1, not '$O365_APPS'"
SNX_RS="${SNX_RS:-1}"
BRAND_BG="${BRAND_BG:-#1e3a5f}"
CLIENT_DE="${CLIENT_DE:-gnome}"
CLIENT_DISTRO="${CLIENT_DISTRO:-ubuntu}"
[[ "$CLIENT_DISTRO" =~ ^(ubuntu|fedora)$ ]] || die "CLIENT_DISTRO must be ubuntu or fedora, not '$CLIENT_DISTRO'"
[[ "$CLIENT_DE" =~ ^(gnome|kde)$ ]] || die "CLIENT_DE must be gnome or kde, not '$CLIENT_DE'"
case "$CLIENT_DISTRO/$CLIENT_DE" in
    ubuntu/gnome) CLIENT_DESKTOP=ubuntu-desktop-minimal CLIENT_DM=gdm3 CLIENT_DM_UNIT=gdm.service ;;
    ubuntu/kde) CLIENT_DESKTOP=kde-plasma-desktop CLIENT_DM=sddm CLIENT_DM_UNIT=sddm.service ;;
    fedora/gnome) CLIENT_DESKTOP=workstation-product-environment CLIENT_DM=gdm CLIENT_DM_UNIT=gdm.service ;;
    fedora/kde) CLIENT_DESKTOP=kde-desktop-environment CLIENT_DM=plasma-login-manager \
                CLIENT_DM_UNIT=plasmalogin.service ;;
esac
if [ "$CLIENT_DISTRO" = fedora ]; then
    CLIENT_ISO="$FEDORA_ISO" CLIENT_INSTALL_ISO="$STAGE/fedora-ks.iso"
    CLIENT_OS_VARIANTS="fedora45 fedora44 fedora-unknown linux2024 linux2022"
else
    CLIENT_ISO="$UBUNTU_ISO" CLIENT_INSTALL_ISO="$STAGE/ubuntu-autoinstall.iso"
    CLIENT_OS_VARIANTS="ubuntu26.04 ubuntu25.10 ubuntu25.04 ubuntu24.04 linux2024 linux2022"
fi
MACHINE_TOKEN_PIN="${MACHINE_TOKEN_PIN:-mld-machine}"
[[ "$MACHINE_TOKEN_PIN" =~ ^[A-Za-z0-9._-]+$ ]] || die "MACHINE_TOKEN_PIN: letters, digits, '.', '_' and '-' only"
UKI_TRUST="${UKI_TRUST:-db}"
[[ "$UKI_TRUST" =~ ^(db|mok)$ ]] || die "UKI_TRUST must be db or mok, not '$UKI_TRUST'"
export IDP NFS_HOME HOME_MODE O365_APPS IDM_GROUP CA_NAME PKI_ENROLL CIFS_HOME SNX_RS CLIENT_DE BRAND_BG BRAND_LOGO \
    CLIENT_DESKTOP CLIENT_DM CLIENT_DM_UNIT CLIENT_DISTRO CLIENT_ISO CLIENT_INSTALL_ISO CLIENT_OS_VARIANTS \
    MACHINE_TOKEN_PIN UKI_TRUST DHCP_START DHCP_END REALM DC_FQDN DOMAIN_DN LINUX_OU LINUX_GROUPS_OU PROBE_USER SMB_SEAL

need_secrets() {
    local v bad=""
    for v in "$@"; do
        [ -n "${!v:-}" ] && [ "${!v}" != CHANGE-ME ] || bad+=" $v"
    done
    [ -z "$bad" ] || die "set these in lab.env:$bad"
}

# render TEMPLATE OUT xml|yaml|none: replaces @@NAME@@ with the environment value of NAME.
render() {
    python3 - "$1" "$2" "$3" <<'PY'
import os, re, sys
src, dst, mode = sys.argv[1:4]
text = open(src, encoding="utf-8").read()
def esc(v):
    if mode == "xml":
        return v.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    if mode == "yaml":
        return v.replace("'", "''")
    if mode == "ks":
        if "\n" in v or "\r" in v:
            sys.exit(f"{src}: a value contains a line break: a kickstart line cannot hold it")
        return v.replace("\\", "\\\\").replace('"', '\\"')
    return v
missing = set()
def sub(m):
    v = os.environ.get(m.group(1))
    if v is None:
        missing.add(m.group(1)); return m.group(0)
    return esc(v)
out = re.sub(r"@@([A-Z0-9_]+)@@", sub, text)
if missing:
    sys.exit(f"{src}: no value for {', '.join(sorted(missing))}")
open(dst, "w", encoding="utf-8").write(out)
PY
}

ps_str() { printf "'%s'" "${1//\'/\'\'}"; }
ps_array() {
    local out="" x
    for x in "$@"; do out+="$(ps_str "$x"),"; done
    printf '@(%s)' "${out%,}"
}
