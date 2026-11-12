# shellcheck shell=bash
# Automatic updates: unattended-upgrades (Ubuntu) or dnf5-automatic (Fedora) each day, reboot at night (mld-reboot).
# Sourced by mld-firstboot (client/mld/firstboot.sh): phase, fail, CFG, STATE and the config.env values are set.

phase_updates() {
    phase updates
    case "$CLIENT_DISTRO" in
    ubuntu)
        pkg_install unattended-upgrades
        install -m 644 "$CFG/update/52mld-unattended-upgrades" /etc/apt/apt.conf.d/52mld-unattended-upgrades
        # The autoinstall stops the timers in the live system only. The installed system can have them off.
        systemctl unmask apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service
        systemctl enable --now apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service mld-reboot.timer
        [ "$(apt-config dump --format '%v' APT::Periodic::Unattended-Upgrade)" = 1 ] \
            || fail "APT::Periodic::Unattended-Upgrade is not 1 (an other file in /etc/apt/apt.conf.d sets it)"
        ;;
    fedora)
        # dnf5-plugins ships "dnf needs-restarting", used by mld-reboot.
        pkg_install dnf5-plugin-automatic dnf5-plugins
        # automatic.conf and the service drop-in come from install.list. dnf5-automatic(8) reads
        # /usr/share/dnf5/dnf5-plugins/automatic.conf, then /etc/dnf/automatic.conf. It warns that the location
        # /etc/dnf/dnf5-plugins/automatic.conf is deprecated: older clients have our copy there.
        if cmp -s "$CFG/update/automatic.conf" /etc/dnf/dnf5-plugins/automatic.conf; then rm -f /etc/dnf/dnf5-plugins/automatic.conf; fi
        systemctl daemon-reload
        systemctl enable --now dnf5-automatic.timer mld-reboot.timer
        ;;
    esac
}
