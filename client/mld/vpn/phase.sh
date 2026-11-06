# shellcheck shell=bash
# snx-rs Check Point VPN client.
# Sourced by mld-firstboot (client/mld/firstboot.sh): phase, fail, CFG, STATE and the config.env values are set.

phase_snx() {
    phase snx
    install -m 644 "$CFG/vpn/snx-rs.sources" /etc/apt/sources.list.d/snx-rs.sources
    if ! dpkg -s snx-rs >/dev/null 2>&1; then
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y snx-rs
    fi
    # The restart ends an open VPN connection, so it occurs only when the drop-in changes.
    local d=/etc/systemd/system/snx-rs.service.d
    if ! cmp -s "$CFG/vpn/snx-rs-tpm.conf" "$d/mld-tpm.conf"; then
        install -D -m 644 "$CFG/vpn/snx-rs-tpm.conf" "$d/mld-tpm.conf"
        systemctl daemon-reload
        systemctl restart snx-rs.service
    fi
    systemctl enable --now snx-rs.service
    systemctl is-active --quiet snx-rs.service || fail "snx-rs.service is not active"
}

phase_snx_remove() {
    dpkg -s snx-rs >/dev/null 2>&1 || [ -e /etc/apt/sources.list.d/snx-rs.sources ] || return 0
    phase snx-remove
    if dpkg -s snx-rs >/dev/null 2>&1; then DEBIAN_FRONTEND=noninteractive apt-get purge -y snx-rs; fi
    rm -f /etc/apt/sources.list.d/snx-rs.sources
    rm -rf /etc/systemd/system/snx-rs.service.d
    systemctl daemon-reload
}
