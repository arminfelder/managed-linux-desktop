# shellcheck shell=bash
# Firefox (Mozilla deb) and Google Chrome.
# Sourced by mld-firstboot (client/mld/firstboot.sh): phase, fail, CFG, STATE and the config.env values are set.

# Ubuntu: Firefox from Mozilla (deb, not the snap). Chrome from Google: its postinst writes google-chrome.sources again
# and installs the key, and its daily cron job updates the key.
# Fedora: Firefox from Fedora. fedora-workstation-repositories has the repo google-chrome (off) and sets
# repo_add_once="false" in /etc/default/google-chrome, so the Chrome postinst writes no repo file.
phase_browsers() {
    phase browsers
    case "$CLIENT_DISTRO" in
    ubuntu)
        install -m 644 "$CFG/apps/mozilla.sources" /etc/apt/sources.list.d/mozilla.sources
        # Pin 1000: the Ubuntu firefox package (1:1snap1, installs the snap) has an epoch and a higher version.
        install -m 644 "$CFG/apps/mozilla.pref" /etc/apt/preferences.d/mozilla.pref
        [ -e /etc/apt/sources.list.d/google-chrome.sources ] ||
            install -m 644 "$CFG/apps/google-chrome.sources" /etc/apt/sources.list.d/google-chrome.sources
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y --allow-downgrades firefox google-chrome-stable
        ;;
    fedora)
        install -D -m 644 "$CFG/apps/google-linux-signing.asc" /etc/pki/rpm-gpg/mld-google-chrome.asc
        rpm --import /etc/pki/rpm-gpg/mld-google-chrome.asc
        if grep -qsx '\[google-chrome\]' /usr/share/dnf5/repos.d/google-chrome.repo; then
            # Our file would be a second repo with the same id. Its key URL is the renewal path for a new Google key.
            if cmp -s "$CFG/apps/google-chrome.repo" /etc/yum.repos.d/google-chrome.repo; then
                rm -f /etc/yum.repos.d/google-chrome.repo
            fi
            pkg_install dnf5-plugins
            dnf config-manager setopt google-chrome.enabled=1
        elif [ ! -e /etc/yum.repos.d/google-chrome.repo ]; then
            install -m 644 "$CFG/apps/google-chrome.repo" /etc/yum.repos.d/google-chrome.repo
        fi
        pkg_install firefox google-chrome-stable
        # Firefox reads the distribution file. samba-gpupdate (gp_firefox_ext) writes the /etc file.
        install -d /etc/firefox/policies
        install -d /usr/lib64/firefox/distribution
        ln -sfn /etc/firefox/policies/policies.json /usr/lib64/firefox/distribution/policies.json
        ;;
    esac
    # p11-kit-trust.so: the GPO loads it into Firefox (SecurityDevices), so that Firefox trusts the AD CAs.
    # The GNOME packages bring it, the KDE packages do not.
    case "$CLIENT_DISTRO" in
    ubuntu)
        pkg_install p11-kit-modules
        dpkg-query -W -f '${Version}' firefox | grep -qv snap || fail "firefox is still the snap package"
        ;;
    fedora) pkg_install p11-kit-trust ;;
    esac
}
