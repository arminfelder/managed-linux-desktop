# shellcheck shell=bash
# Runs as the AD user in an ssh session (TGT from pam_sss). Prints KEY=VALUE lines for client verify.
# A new service ticket for HTTP/<dc> shows that the browser trusted the TLS certificate (AD CA) and did Kerberos
# (GPO allowlist). No --ignore-certificate-errors.
# Chrome first, with the session ticket cache (FILE:/tmp/krb5cc_<uid>, as in a desktop session): the Chrome network
# service may not read other files. Firefox then with its own copy, so that the ticket from Chrome does not count.
url="https://$DC_FQDN/certsrv/"
src=$(klist 2>/dev/null | sed -n 's/^Ticket cache: //p')
# probe NAME: runs the browser with its own ticket cache copy and a new profile, then counts HTTP/<dc> tickets.
probe() {
    local name=$1 cc tmp
    tmp=$(mktemp -d)
    if [ "$name" = firefox ]; then cc=$(mktemp); cp "${src#FILE:}" "$cc"; else cc=${src#FILE:}; fi
    echo "${name}_http_before=$(klist -c "$cc" 2>/dev/null | grep -c "HTTP/$DC_FQDN")"
    case "$name" in
        chrome) KRB5CCNAME="FILE:$cc" timeout 90 google-chrome-stable --headless=new --disable-gpu --no-first-run \
                    --user-data-dir="$tmp" --log-net-log="$tmp/net.json" --dump-dom "$url" >/dev/null 2>&1 || true
                # Short NetLog summary for a failed test: auth schemes, network errors, HTTP status lines.
                echo "chrome_netlog=$(grep -o -E '"scheme":"[a-z]+"|"net_error":-3[0-9]{2}|HTTP/1\.1 401|www-authenticate: [A-Za-z]+|[A-Za-z_ ]*[Gg][Ss][Ss][Aa][Pp][Ii][^"]{0,60}' "$tmp/net.json" 2>/dev/null | sort | uniq -c | tr -s ' \n' ' ')" ;;
        firefox) KRB5CCNAME="FILE:$cc" timeout 90 firefox --headless --no-remote -profile "$tmp" \
                    --screenshot "$tmp/shot.png" "$url" >/dev/null 2>&1 || true ;;
    esac
    echo "${name}_http_ticket=$(klist -c "$cc" 2>/dev/null | grep -c "HTTP/$DC_FQDN")"
    if [ "$name" = firefox ]; then rm -f "$cc"; fi
    rm -rf "$tmp"
}
probe chrome
probe firefox
