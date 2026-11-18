#!/bin/bash
# Certificates from AD CS with the private key in the TPM (tpm2-openssl). The key never leaves the TPM:
# the key file is a TPM-wrapped blob ("TSS2 PRIVATE KEY") that only this TPM can load.
#
#   mld-cert ca                      root: trust the CA certificates that AD publishes (system store, Chrome policy)
#   mld-cert machine [web|dcom]      root: machine certificate, template Machine, machine Kerberos ticket
#   mld-cert user [web|dcom]         AD user: user certificate, template User, the user's Kerberos ticket
#   mld-cert check machine|user      key in the TPM, certificate matches the key, TPM signs, chain verifies
#   mld-cert submit WHO HOW TEMPLATE CSR OUT   submit a CSR only (certmonger helper), exit 0/2/3/5
#
# web  = https://<dc>/certsrv/certfnsh.asp (certsrv web enrollment, Negotiate/Kerberos)
# dcom = ICertRequestD::Request (MS-WCCE over DCOM, Kerberos), see /usr/local/sbin/mld-cert-dcom
set -euo pipefail
# /etc/mld is root-only. The pki phase of first boot copies the values for mld-cert to this public file.
# shellcheck source=/dev/null
. /etc/mld-cert.conf

# One file mld-<fingerprint>.crt per AD CA certificate in CA_DIR, and all of them in one bundle.
# CA_PREFIX scopes every glob: on Fedora the directory (anchors) holds foreign files too.
CA_BUNDLE=/etc/mld-ca.pem
CHROME_CA=/etc/opt/chrome/policies/managed/mld-ca.json
# propquery: prefer the TPM provider for key operations; "default" does the rest (encoding, hashing).
TPM=(-provider tpm2 -provider default -propquery '?provider=tpm2')
# certsrv requires SSL. curl trusts the CA after "mld-cert ca" (system store).
CERTSRV="https://$DC_FQDN/certsrv"

die() { echo "mld-cert: $*" >&2; exit 1; }

# Old mld-cert.conf files (Ubuntu only) have no CA_ANCHOR_DIR.
CLIENT_DISTRO=${CLIENT_DISTRO:-ubuntu}
if [ -z "${CA_ANCHOR_DIR:-}" ]; then
    [ "$CLIENT_DISTRO" = ubuntu ] || die "CA_ANCHOR_DIR missing in /etc/mld-cert.conf: run ./build.sh client resume"
    CA_ANCHOR_DIR=/usr/local/share/ca-certificates/mld CA_ANCHOR_PREFIX=
fi
CA_DIR=$CA_ANCHOR_DIR CA_PREFIX=${CA_ANCHOR_PREFIX:-}

machine_ticket() {
    export KRB5CCNAME=FILE:/run/mld-machine.ccache
    kinit -k "$(hostname -s | tr '[:lower:]' '[:upper:]')\$@$REALM" || die "no machine ticket (keytab)"
}

# TPM-bound user files stay on this device: the home can roam (CIFS), the TPM does not.
# /var/lib/mld-users has mode 1733 (firstboot). The directory of the user must be owned by the user, mode 700.
user_state() {
    local d; d="/var/lib/mld-users/$(id -u)"
    [ -d "$d" ] || install -d -m 700 "$d"
    [ "$(stat -c %u:%a "$d")" = "$(id -u):700" ] || die "$d must be owned by $(id -un) with mode 700"
    printf '%s' "$d"
}

setup() {
    case "$1" in
        machine)
            [ "$(id -u)" = 0 ] || die "machine needs root"
            DIR=/etc/mld/pki TEMPLATE=Machine SUBJECT="/CN=$(hostname -f)"
            machine_ticket ;;
        user)
            [ "$(id -u)" != 0 ] || die "run as the AD user, not root"
            DIR="$(user_state)/mld-pki" TEMPLATE=User SUBJECT="/CN=$USER"
            klist -s || die "no Kerberos ticket: log in with the AD password or run kinit" ;;
        *) die "machine or user, not '$1'" ;;
    esac
    KEY="$DIR/$1.tss" CRT="$DIR/$1.crt"
    install -d -m 700 "$DIR"
}

# submit_csr web|dcom TEMPLATE CSR_PEM OUT_PEM: sends the request, writes the issued certificate.
# Return codes as for a certmonger helper: 0 issued, 2 rejected, 3 CA unreachable, 5 pending.
submit_csr() {
    local how="$1" template="$2" csr="$3" out="$4" resp id rc
    case "$how" in
        web)
            resp=$(curl -sS --fail --negotiate -u : \
                --data-urlencode "CertRequest@$csr" -d Mode=newreq -d "CertAttrib=CertificateTemplate:$template" \
                -d TargetStoreFlags=0 -d SaveCert=yes -d ThumbPrint= "$CERTSRV/certfnsh.asp") \
                || { echo "certsrv not reachable" >&2; return 3; }
            id=$(printf '%s' "$resp" | grep -o 'certnew.cer?ReqID=[0-9]*' | head -1 | cut -d= -f2)
            if [ -z "$id" ]; then
                echo "certsrv: $(printf '%s' "$resp" | sed 's/<[^>]*>//g' |
                    grep -iE 'disposition|denied|pending|error|0x' | head -3 | tr -s ' \n' ' ')" >&2
                printf '%s' "$resp" | grep -qi 'pending' && return 5
                return 2
            fi
            curl -sS --fail --negotiate -u : -o "$out" "$CERTSRV/certnew.cer?ReqID=$id&Enc=b64" \
                || { echo "could not get certificate $id" >&2; return 3; }
            echo "certsrv: request $id issued" >&2 ;;
        dcom)
            openssl req -in "$csr" -outform DER -out "$csr.der"
            # "|| rc=$?": under set -e a failed helper must not end the script before the code is mapped.
            rc=0
            /usr/local/sbin/mld-cert-dcom "$DC_FQDN" "$CA_NAME" "$template" "$csr.der" "$out.der" || rc=$?
            rm -f "$csr.der"
            case "$rc" in
                0) openssl x509 -inform DER -in "$out.der" -out "$out"; rm -f "$out.der" ;;
                2) return 5 ;;
                *) return 2 ;;
            esac ;;
        *) echo "web or dcom, not '$how'" >&2; return 2 ;;
    esac
}

enroll() {
    local who="$1" how="${2:-web}" csr
    setup "$who"
    if [ ! -s "$KEY" ]; then
        ( umask 077; openssl genpkey "${TPM[@]}" -algorithm RSA -pkeyopt bits:2048 -out "$KEY" )
    fi
    grep -q 'BEGIN TSS2 PRIVATE KEY' "$KEY" || die "$KEY is not a TPM key"
    csr="$DIR/$who.csr"
    openssl req "${TPM[@]}" -new -key "$KEY" -subj "$SUBJECT" -out "$csr"

    submit_csr "$how" "$TEMPLATE" "$csr" "$CRT.new" || die "request failed (code $?)"

    [ "$(openssl x509 -in "$CRT.new" -noout -pubkey)" = "$(openssl pkey "${TPM[@]}" -in "$KEY" -pubout)" ] \
        || die "the certificate does not match the TPM key"
    mv "$CRT.new" "$CRT"
    openssl x509 -in "$CRT" -noout -subject -issuer -enddate
}

check() {
    setup "$1"
    [ -s "$CRT" ] || die "no certificate $CRT"
    grep -q 'BEGIN TSS2 PRIVATE KEY' "$KEY" || die "key is not TPM-wrapped"
    echo "key=tpm"
    [ "$(openssl x509 -in "$CRT" -noout -pubkey)" = "$(openssl pkey "${TPM[@]}" -in "$KEY" -pubout)" ] \
        && echo "match=yes" || echo "match=no"
    local tmp; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN
    echo "mld-cert probe $(date +%s)" > "$tmp/data"
    openssl x509 -in "$CRT" -noout -pubkey > "$tmp/pub"
    if openssl dgst "${TPM[@]}" -sha256 -sign "$KEY" -out "$tmp/sig" "$tmp/data" \
        && openssl dgst -sha256 -verify "$tmp/pub" -signature "$tmp/sig" "$tmp/data" >/dev/null; then
        echo "tpm_sign=yes"
    else
        echo "tpm_sign=no"
    fi
    openssl verify -CAfile "$CA_BUNDLE" "$CRT" >/dev/null 2>&1 && echo "chain=yes" || echo "chain=no"
    echo "subject=$(openssl x509 -in "$CRT" -noout -subject -nameopt RFC2253 | sed 's/^subject=//')"
    echo "issuer=$(openssl x509 -in "$CRT" -noout -issuer -nameopt RFC2253 | sed 's/^issuer=//')"
}

cmd_ca() {
    [ "$(id -u)" = 0 ] || die "ca needs root"
    # Root only: /etc/mld is readable here. Source before the RETURN trap: a sourced file would fire it.
    # shellcheck source=/dev/null
    CLIENT_DISTRO=$(. /etc/mld/config.env && echo "$CLIENT_DISTRO") \
        || die "missing /etc/mld/config.env: run ./build.sh client resume"
    export CLIENT_DISTRO
    # shellcheck source=/dev/null
    . /etc/mld/distro.sh || die "missing /etc/mld/distro.sh: run ./build.sh client resume"
    CA_DIR=$CA_ANCHOR_DIR CA_PREFIX=$CA_ANCHOR_PREFIX
    machine_ticket
    # As on Windows: trust each CA certificate in this AD container. A renewed CA adds a value to cACertificate.
    # From AD over LDAP (Kerberos, signed): https to certsrv needs the CA first.
    local base="CN=Certification Authorities,CN=Public Key Services,CN=Services,CN=Configuration,$DOMAIN_DN"
    local tmp b64 fp f changed=0 n=0 list=""
    tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN
    mkdir "$tmp/new"
    ldapsearch -Q -N -LLL -o ldif-wrap=no -Y GSSAPI -H "ldap://$DC_FQDN" -b "$base" -s one \
        '(objectClass=certificationAuthority)' cACertificate > "$tmp/ldif" || die "LDAP search in $base failed"
    while read -r b64; do
        if ! printf '%s' "$b64" | base64 -d | openssl x509 -inform DER -out "$tmp/pem" 2>/dev/null; then
            echo "mld-cert: a cACertificate value in $base is not a certificate, skipped" >&2; continue
        fi
        fp=$(openssl x509 -in "$tmp/pem" -noout -fingerprint -sha256 | sed 's/.*=//; s/://g' | cut -c1-16)
        mv "$tmp/pem" "$tmp/new/mld-$fp.crt"
        n=$((n + 1))
    done < <(sed -n 's/^cACertificate:: //p' "$tmp/ldif")
    [ "$n" -gt 0 ] || die "no CA certificate in $base"

    install -d -m 755 "$CA_DIR"
    for f in "$CA_DIR"/${CA_PREFIX}*.crt; do
        if [ -e "$f" ] && [ ! -e "$tmp/new/${f##*/}" ]; then
            rm -f "$f"; changed=1; echo "removed: ${f##*/} (not in AD)"
        fi
    done
    for f in "$tmp/new"/*.crt; do
        if ! cmp -s "$f" "$CA_DIR/${f##*/}"; then install -m 644 "$f" "$CA_DIR/"; changed=1; echo "added: ${f##*/}"; fi
    done
    # Older Ubuntu versions had one file for the CA named CA_NAME.
    if [ "$CLIENT_DISTRO" = ubuntu ] && [ -e /usr/local/share/ca-certificates/mld-ca.crt ]; then
        rm -f /usr/local/share/ca-certificates/mld-ca.crt; changed=1
    fi
    if [ "$changed" = 1 ]; then ca_trust_update; fi

    cat "$CA_DIR"/${CA_PREFIX}*.crt > "$tmp/bundle"
    cmp -s "$tmp/bundle" "$CA_BUNDLE" || install -m 644 "$tmp/bundle" "$CA_BUNDLE"
    # Chrome does not read the system store on Linux. The policy gives it the same certificates (DER, base64).
    for f in "$CA_DIR"/${CA_PREFIX}*.crt; do
        list+="${list:+, }\"$(openssl x509 -in "$f" -outform DER | base64 -w0)\""
    done
    printf '{\n  "CACertificates": [%s]\n}\n' "$list" > "$tmp/chrome.json"
    cmp -s "$tmp/chrome.json" "$CHROME_CA" || install -D -m 644 "$tmp/chrome.json" "$CHROME_CA"
    for f in "$CA_DIR"/${CA_PREFIX}*.crt; do
        echo "${f##*/}: $(openssl x509 -in "$f" -noout -subject -enddate -nameopt RFC2253 | tr '\n' ' ')"
    done
}

case "${1:-}" in
    ca) cmd_ca ;;
    machine|user) enroll "$@" ;;
    submit)
        # mld-cert submit machine|user web|dcom TEMPLATE CSR_PEM OUT_PEM (for the certmonger helper)
        [ $# -eq 6 ] || die "usage: mld-cert submit machine|user web|dcom TEMPLATE CSR OUT"
        if [ "$2" = machine ]; then machine_ticket >&2; fi
        submit_csr "$3" "$4" "$5" "$6"; exit $? ;;
    check) check "${2:-}" ;;
    *) sed -n '2,12p' "$0"; exit 2 ;;
esac
