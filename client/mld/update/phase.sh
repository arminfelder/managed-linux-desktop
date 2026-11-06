# shellcheck shell=bash
# Automatic updates: unattended-upgrades (Ubuntu, Firefox, Chrome, snx-rs) each day, reboot at night (mld-reboot).
# Sourced by mld-firstboot (client/mld/firstboot.sh): phase, fail, CFG, STATE and the config.env values are set.

phase_updates() {
    phase updates
    pkg_install unattended-upgrades
    install -m 644 "$CFG/update/52mld-unattended-upgrades" /etc/apt/apt.conf.d/52mld-unattended-upgrades
    # The autoinstall stops the timers in the live system only. The installed system can have them off.
    systemctl unmask apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service
    systemctl enable --now apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service mld-reboot.timer
    [ "$(apt-config dump --format '%v' APT::Periodic::Unattended-Upgrade)" = 1 ] \
        || fail "APT::Periodic::Unattended-Upgrade is not 1 (an other file in /etc/apt/apt.conf.d sets it)"
}
