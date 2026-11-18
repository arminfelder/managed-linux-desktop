# shellcheck shell=bash
# Microsoft 365 launchers, icons, dock pins, desktop folder.
# Sourced by mld-firstboot (client/mld/firstboot.sh): phase, fail, CFG, STATE and the config.env values are set.

# Microsoft 365 apps as Chrome app windows: launcher in /usr/share/applications, dock pins (dconf), desktop icons
# (user unit mld-desktop). The launchers exist before the first Chrome start, unlike installed web apps.
phase_desktop() {
    phase desktop
    desktop_check_de
    # An older version installed the apps through WebAppInstallForceList: each app then showed twice.
    rm -f /etc/opt/chrome/policies/managed/mld-o365.json
    # The local desktop folders are in the per-device user directories (see phase_pki).
    install -d -m 1733 -o root -g root /var/lib/mld-users
    local base=https://res-1.cdn.office.net/files/fabric-cdn-prod_20240129.001/assets/brand-icons/product/svg
    local icons=/usr/share/icons/hicolor/scalable/apps
    install -d -m 755 "$icons"
    # O365_APPS=0 (default with IDP=freeipa): no Microsoft 365 launchers, and the ones of an earlier build go.
    # Do not gate inside the read loop: awk then gets SIGPIPE and the subshell ERR trap writes FAILED (seen 2026-11-18).
    if [ "${O365_APPS:-1}" != 1 ]; then
        rm -f /usr/share/applications/mld-o365-*.desktop "$icons"/mld-o365-*.svg
    else
        desktop_o365_apps "$base" "$icons"
    fi
    gtk-update-icon-cache -q -f /usr/share/icons/hicolor 2>/dev/null || true
    update-desktop-database -q /usr/share/applications 2>/dev/null || true
    desktop_pins
    desktop_user_unit
}

# Launchers and icons from o365-apps.list. Arguments: icon CDN base URL, icon directory.
desktop_o365_apps() {
    local base=$1 icons=$2 id name url icon sum tmp
    while read -r id name url icon sum; do
        name=${name//_/ }
        if ! echo "$sum  $icons/mld-o365-$id.svg" | sha256sum -c --status 2>/dev/null; then
            tmp=$(mktemp)
            # A reset connection (curl 35) is not a transient error for --retry alone.
            curl -fsS --retry 5 --retry-all-errors --retry-delay 3 -o "$tmp" "$base/${icon}_48x1.svg"
            echo "$sum  $tmp" | sha256sum -c --status || { rm -f "$tmp"; fail "icon $icon: sha256 differs"; }
            install -m 644 "$tmp" "$icons/mld-o365-$id.svg"; rm -f "$tmp"
        fi
        printf '%s\n' '[Desktop Entry]' 'Type=Application' "Name=$name" "Comment=$name (Microsoft 365 web app)" \
            "Exec=/usr/bin/google-chrome-stable --app=$url" "Icon=mld-o365-$id" 'Categories=Office;' \
            'Terminal=false' > "/usr/share/applications/mld-o365-$id.desktop"
    # lint: disable=line-length (quoted awk program)
    done < <(awk '!/^#/ && NF { n = $2; for (i = 3; i < NF - 2; i++) n = n "_" $i; print $1, n, $(NF-2), $(NF-1), $NF }' "$CFG/desktop/o365-apps.list")
}

# Fedora GNOME stays stock: no desktop icons, so no mld-desktop. An older build may have enabled it.
desktop_user_unit() {
    if [ "${CLIENT_DISTRO:-ubuntu}" = fedora ] && [ "${CLIENT_DE:-gnome}" = gnome ]; then
        systemctl --global disable mld-desktop.service
    else
        systemctl --global enable mld-desktop.service
    fi
}

# The client has one desktop (CLIENT_DE). client resume does not swap it: that needs a new client build.
desktop_check_de() {
    local have=""
    if [ -x /usr/bin/gnome-shell ]; then have=gnome; fi
    if [ -x /usr/bin/plasmashell ]; then have=${have:+$have+}kde; fi
    [ "$have" = "${CLIENT_DE:-gnome}" ] \
        || fail "CLIENT_DE=${CLIENT_DE:-gnome}, but the client has '${have:-no desktop}': build the client again"
}

# SDDM lists only local users, so the AD users (sssd) are not in the list. Without a list, the Breeze login screen asks
# for the user name and the password, as the Windows login does. GDM has "Not listed?" for the same case.
desktop_sddm() {
    local f=/etc/sddm.conf.d/90-mld.conf bg=/usr/share/mld/brand/background.png
    local user=/usr/share/sddm/themes/breeze/theme.conf.user tmp sim changed=0
    pkg_install sddm-theme-breeze
    case "$CLIENT_DISTRO" in
    ubuntu)
        # kde-plasma-desktop brings budgie-sddm-theme. Its 50-ubuntu-budgie.conf selects the Budgie greeter:
        # a white screen under Plasma. Purge it only when apt removes nothing else.
        if dpkg -s budgie-sddm-theme >/dev/null 2>&1; then
            sim=$(apt-get -s purge budgie-sddm-theme |
                grep -E '^(Purg|Remv) ' | grep -v '^Purg budgie-sddm-theme ' || true)
            [ -z "$sim" ] || fail "a purge of budgie-sddm-theme also removes: $sim"
            DEBIAN_FRONTEND=noninteractive apt-get purge -y budgie-sddm-theme
            changed=1
        fi
        ;;
    esac
    rm -f /etc/sddm.conf.d/50-mld.conf
    tmp=$(mktemp)
    # No user list: the login screen asks for the user name (AD users).
    printf '%s\n' '# Written by mld-firstboot (desktop_sddm).' '[Users]' 'MaximumUid=999' \
        '[Theme]' 'Current=breeze' 'CursorTheme=breeze_cursors' > "$tmp"
    cmp -s "$tmp" "$f" || { install -D -m 644 "$tmp" "$f"; changed=1; }
    printf '%s\n' '[General]' "background=$bg" 'type=image' > "$tmp"
    cmp -s "$tmp" "$user" || { install -m 644 "$tmp" "$user"; changed=1; }
    rm -f "$tmp"
    [ "$changed" = 1 ] || return 0
    # A restart ends the open desktop sessions. Without a user session, restart now;
    # else the change waits for the reboot.
    if loginctl list-sessions --no-legend | awk '$3 != "sddm" && $4 == "seat0"' | grep -q .; then
        echo "SDDM settings changed: active after the next reboot (a user session is open)"
    else
        systemctl restart sddm.service
    fi
}

# Fedora 45 KDE uses Plasma Login Manager. Its package has no key for the user list (no MaximumUid, no HideUsers), so
# the list stays as the package sets it. The background is the Greeter wallpaper group of kde-settings-plasmalogin.
desktop_plasmalogin() {
    local f=/etc/plasmalogin.conf.d/90-mld.conf bg=/usr/share/mld/brand/background.png tmp
    tmp=$(mktemp)
    printf '%s\n' '# Written by mld-firstboot (desktop_plasmalogin).' '[Greeter]' 'WallpaperPlugin=org.kde.image' \
        '[Greeter][Wallpaper][org.kde.image][General]' "Image=file://$bg" "PreviewImage=file://$bg" > "$tmp"
    if cmp -s "$tmp" "$f"; then rm -f "$tmp"; return 0; fi
    install -D -m 644 "$tmp" "$f"
    rm -f "$tmp"
    if loginctl list-sessions --no-legend | awk '$3 != "plasmalogin" && $4 == "seat0"' | grep -q .; then
        echo "Plasma Login Manager settings changed: active after the next reboot (a user session is open)"
    else
        systemctl restart plasmalogin.service
    fi
}

# Ubuntu has no profile: ours names the user and the local database. The Fedora profile belongs to the dconf package
# (user, local, site, distro). It stays, and gets the local line only if it has none.
desktop_dconf_profile() {
    local f=/etc/dconf/profile/user
    case "${CLIENT_DISTRO:-ubuntu}" in
    ubuntu) install -D -m 644 "$CFG/desktop/dconf-user.profile" "$f" ;;
    fedora)
        if [ ! -s "$f" ]; then install -D -m 644 "$CFG/desktop/dconf-user.profile" "$f"
        elif ! grep -qx 'system-db:local' "$f"; then echo 'system-db:local' >> "$f"; fi
        ;;
    esac
}

# One pin list for both desktops: the GNOME dock (dconf default) and the KDE task manager (Plasma update script).
desktop_pins() {
    # The script goes into the updates folder of the installed shell package. A folder with the same package name in
    # /usr/local/share comes first in XDG_DATA_DIRS and has no metadata: plasmashell then loads no desktop and no
    # panel ("Invalid corona package metadata", black screen). Old clients have that folder.
    local fm ff p js=/usr/share/plasma/shells/org.kde.plasma.desktop/contents/updates/mld-pins.js
    local pins=()
    rm -rf /usr/local/share/plasma/shells/org.kde.plasma.desktop
    rmdir --ignore-fail-on-non-empty /usr/local/share/plasma/shells /usr/local/share/plasma 2>/dev/null || true
    case "${CLIENT_DE:-gnome}" in gnome) fm=org.gnome.Nautilus.desktop ;; kde) fm=org.kde.dolphin.desktop ;; esac
    case "${CLIENT_DISTRO:-ubuntu}" in ubuntu) ff=firefox.desktop ;; fedora) ff=org.mozilla.firefox.desktop ;; esac
    while read -r p; do
        [ "${O365_APPS:-1}" = 1 ] || [[ "$p" != mld-o365-* ]] || continue
        p=${p/#@filemanager/$fm}; pins+=("${p/#@firefox/$ff}")
    done < <(grep -v -E '^\s*(#|$)' "$CFG/desktop/pins.list")
    if [ "${CLIENT_DE:-gnome}" = gnome ]; then
        rm -f "$js"
        desktop_dconf_profile
        install -d -m 755 /etc/dconf/db/local.d
        { echo '# Generated by mld-firstboot from /etc/mld/desktop/pins.list. A user setting wins over this default.'
          echo '[org/gnome/shell]'
          printf "favorite-apps=[%s]\n" "$(printf "'%s', " "${pins[@]}" | sed 's/, $//')"
        } > /etc/dconf/db/local.d/10-mld-desktop
        dconf update
    else
        # The Ubuntu profile is ours and names the system database "local". Without the database, each GTK program
        # writes a warning. The Fedora profile belongs to the dconf package: it stays.
        rm -f /etc/dconf/db/local.d/10-mld-desktop
        [ "${CLIENT_DISTRO:-ubuntu}" = fedora ] || rm -f /etc/dconf/profile/user
        if command -v dconf >/dev/null; then dconf update; fi
        case "${CLIENT_DISTRO:-ubuntu}" in
        ubuntu) desktop_sddm ;;
        fedora) desktop_plasmalogin ;;
        esac
        # plasmashell runs each update script one time per user, at the next login (plasmashellrc, [Updates]).
        install -d -m 755 "${js%/*}"
        { echo '// Generated by mld-firstboot from /etc/mld/desktop/pins.list:' \
               'pins in the task manager, as the GNOME dock.'
          printf 'var launchers = [%s];\n' "$(printf '"applications:%s", ' "${pins[@]}" | sed 's/, $//')"
          echo 'panels().forEach(function (panel) {'
          echo '    panel.widgets("org.kde.plasma.icontasks").forEach(function (w) {'
          echo '        w.currentConfigGroup = ["General"];'
          echo '        w.writeConfig("launchers", launchers);'
          echo '    });'
          echo '});'
        } > "$js"
    fi
}
