# shellcheck shell=bash
# snx-rs Check Point VPN client.
# Sourced by mld-firstboot (client/mld/firstboot.sh): phase, fail, CFG, STATE and the config.env values are set.

phase_snx() {
    phase snx
    case "$CLIENT_DISTRO" in
    ubuntu)
        install -m 644 "$CFG/vpn/snx-rs.sources" /etc/apt/sources.list.d/snx-rs.sources
        if ! dpkg -s snx-rs >/dev/null 2>&1; then
            apt-get update
            DEBIAN_FRONTEND=noninteractive apt-get install -y snx-rs
        fi
        ;;
    fedora)
        install -D -m 644 "$CFG/vpn/snx-rs.asc" /etc/pki/rpm-gpg/mld-snx-rs.asc
        install -m 644 "$CFG/vpn/snx-rs.repo" /etc/yum.repos.d/snx-rs.repo
        pkg_install snx-rs
        ;;
    esac
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
    case "$CLIENT_DISTRO" in
    ubuntu)
        dpkg -s snx-rs >/dev/null 2>&1 || [ -e /etc/apt/sources.list.d/snx-rs.sources ] || return 0
        phase snx-remove
        if dpkg -s snx-rs >/dev/null 2>&1; then DEBIAN_FRONTEND=noninteractive apt-get purge -y snx-rs; fi
        rm -f /etc/apt/sources.list.d/snx-rs.sources
        ;;
    fedora)
        pkg_installed snx-rs || [ -e /etc/yum.repos.d/snx-rs.repo ] || return 0
        phase snx-remove
        pkg_purge snx-rs
        rm -f /etc/yum.repos.d/snx-rs.repo /etc/pki/rpm-gpg/mld-snx-rs.asc
        ;;
    esac
    rm -rf /etc/systemd/system/snx-rs.service.d
    systemctl daemon-reload
}
