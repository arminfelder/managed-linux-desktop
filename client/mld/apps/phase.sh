# shellcheck shell=bash
# Firefox (Mozilla deb) and Google Chrome.
# Sourced by mld-firstboot (client/mld/firstboot.sh): phase, fail, CFG, STATE and the config.env values are set.

# Firefox from Mozilla (deb, not the snap). Chrome from Google: its postinst writes google-chrome.sources again
# and installs the key, and its daily cron job updates the key.
phase_browsers() {
    phase browsers
    install -m 644 "$CFG/apps/mozilla.sources" /etc/apt/sources.list.d/mozilla.sources
    # Pin 1000: the Ubuntu firefox package (1:1snap1, installs the snap) has an epoch and a higher version.
    install -m 644 "$CFG/apps/mozilla.pref" /etc/apt/preferences.d/mozilla.pref
    [ -e /etc/apt/sources.list.d/google-chrome.sources ] ||
        install -m 644 "$CFG/apps/google-chrome.sources" /etc/apt/sources.list.d/google-chrome.sources
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --allow-downgrades firefox google-chrome-stable
    # p11-kit-trust.so: the GPO loads it into Firefox (SecurityDevices), so that Firefox trusts the AD CAs.
    # The GNOME packages bring it, the KDE packages do not.
    pkg_install p11-kit-modules
    dpkg-query -W -f '${Version}' firefox | grep -qv snap || fail "firefox is still the snap package"
}
