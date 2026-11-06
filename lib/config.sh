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
PKI_ENROLL="${PKI_ENROLL:-web}"
PKI_ENROLL="${PKI_ENROLL,,}"
[[ "$PKI_ENROLL" =~ ^(web|dcom|none)$ ]] || die "PKI_ENROLL must be web, dcom or none, not '$PKI_ENROLL'"
CIFS_HOME="${CIFS_HOME:-1}"
SNX_RS="${SNX_RS:-1}"
BRAND_BG="${BRAND_BG:-#1e3a5f}"
CLIENT_DE="${CLIENT_DE:-gnome}"
case "$CLIENT_DE" in
    gnome) CLIENT_DESKTOP=ubuntu-desktop-minimal CLIENT_DM=gdm3 ;;
    kde) CLIENT_DESKTOP=kde-plasma-desktop CLIENT_DM=sddm ;;
    *) die "CLIENT_DE must be gnome or kde, not '$CLIENT_DE'" ;;
esac
MACHINE_TOKEN_PIN="${MACHINE_TOKEN_PIN:-mld-machine}"
[[ "$MACHINE_TOKEN_PIN" =~ ^[A-Za-z0-9._-]+$ ]] || die "MACHINE_TOKEN_PIN: letters, digits, '.', '_' and '-' only"
UKI_TRUST="${UKI_TRUST:-db}"
[[ "$UKI_TRUST" =~ ^(db|mok)$ ]] || die "UKI_TRUST must be db or mok, not '$UKI_TRUST'"
export CA_NAME PKI_ENROLL CIFS_HOME SNX_RS CLIENT_DE BRAND_BG BRAND_LOGO CLIENT_DESKTOP CLIENT_DM MACHINE_TOKEN_PIN UKI_TRUST DHCP_START DHCP_END REALM DC_FQDN DOMAIN_DN LINUX_OU LINUX_GROUPS_OU PROBE_USER SMB_SEAL

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
