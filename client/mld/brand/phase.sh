# shellcheck shell=bash
# Boot screen (Plymouth theme "mld") and login screen (SDDM Breeze) with the logo and color from lab.env.
# Sourced by mld-firstboot (client/mld/firstboot.sh): phase, fail, CFG, STATE and the config.env values are set.

BRAND_DIR=/usr/share/mld/brand
PLY_DIR=/usr/share/plymouth/themes/mld

brand_plymouth() {
    local bg=${BRAND_BG:-#1e3a5f} new old img=$(initrd_path "$(uname -r)")
    pkg_install plymouth plymouth-theme-spinner
    if [ "$CLIENT_DISTRO" = fedora ]; then pkg_install plymouth-scripts; fi
    mkdir -p "$PLY_DIR"
    # two-step loads its images from ImageDir: the spinner frames, the passphrase box, and watermark.png (the logo).
    cp /usr/share/plymouth/themes/spinner/*.png "$PLY_DIR/"
    install -m 644 "$BRAND_DIR/logo.png" "$PLY_DIR/watermark.png"
    sed "s/BRAND_BG_HEX/${bg#\#}/g" "$CFG/brand/mld.plymouth" > "$PLY_DIR/mld.plymouth"
    mkdir -p /etc/plymouth
    printf '[Daemon]\nTheme=mld\n' > /etc/plymouth/plymouthd.conf
    case "$CLIENT_DISTRO" in
    ubuntu)
        update-alternatives --install /usr/share/plymouth/themes/default.plymouth default.plymouth \
            "$PLY_DIR/mld.plymouth" 300
        update-alternatives --set default.plymouth "$PLY_DIR/mld.plymouth"
        ;;
    fedora)
        plymouth-set-default-theme mld
        ;;
    esac
    echo 'add_dracutmodules+=" plymouth "' > /etc/dracut.conf.d/91-mld-plymouth.conf
    # The theme is in the initrd (and the UKI). Make them again only when the theme changed: dracut takes minutes.
    new=$(cat "$PLY_DIR"/mld.plymouth "$PLY_DIR"/watermark.png | sha256sum | cut -d' ' -f1)
    old=$(cat "$STATE/plymouth.sha" 2>/dev/null || true)
    # One call each: with pipefail, "lsinitrd | grep -q" fails when grep closes the pipe early (SIGPIPE).
    if [ "$new" != "$old" ] || ! grep -q 'plymouth/themes/mld/mld.plymouth' <<<"$(lsinitrd "$img")"; then
        dracut --force --regenerate-all
        if [ "${UKI:-0}" = 1 ]; then /usr/local/sbin/mld-uki all || fail "UKI rebuild failed"; fi
        echo "$new" > "$STATE/plymouth.sha"
    fi
    grep -q 'plymouth/themes/mld/watermark.png' <<<"$(lsinitrd "$img")" \
        || fail "the initrd has no Plymouth theme mld (dracut module plymouth missing?)"
}

phase_brand() {
    phase brand
    [ -s "$BRAND_DIR/logo.png" ] || fail "$BRAND_DIR/logo.png is missing (build.sh makes it from BRAND_LOGO)"
    brand_plymouth
}
