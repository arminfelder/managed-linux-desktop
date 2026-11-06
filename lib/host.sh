# Sourced by build.sh: host prerequisites, media, libvirt network and pool.
# shellcheck shell=bash

# report OK_TEXT MISSING_TEXT CMD...: prints "ok" or "MISSING" for CMD. A failed CMD sets missing=1 in cmd_check.
report() {
    local ok="$1" bad="$2"; shift 2
    if "$@" >/dev/null 2>&1; then printf '  ok      %s\n' "$ok"
    else printf '  MISSING %s\n' "$bad"; missing=1; fi
}

ovmf_present() { [ -e /usr/share/OVMF/OVMF_CODE_4M.secboot.fd ] && [ -e /usr/share/OVMF/OVMF_VARS_4M.ms.fd ]; }

cmd_check() {
    local missing=0 bin
    # magick: the boot and login screen images (BRAND_LOGO), and PNG screenshots.
    for bin in virsh virt-install virt-xml genisoimage xorriso openssl python3 sha256sum curl magick; do
        if command -v "$bin" >/dev/null 2>&1; then printf '  ok      %s\n' "$bin"
        else printf '  MISSING %s\n' "$bin"; missing=1; fi
    done
    for bin in sshpass; do
        if command -v "$bin" >/dev/null 2>&1; then printf '  ok      %s\n' "$bin"
        else printf '  OPTIONAL %s (client verify login test)\n' "$bin"; fi
    done
    report "OVMF Secure Boot firmware + MS key vars" "OVMF secboot firmware (package ovmf)" ovmf_present
    if [ "${UKI:-0}" = 1 ] && [ "$UKI_TRUST" = db ]; then
        report "virt-fw-vars (UKI=1, UKI_TRUST=db)" \
            "virt-fw-vars (UKI=1, package python3-virt-firmware or pip install virt-firmware)" command -v virt-fw-vars
    fi
    if [ "${UKI:-0}" = 1 ] && [ "$UKI_TRUST" = mok ]; then
        report "mokutil (UKI_TRUST=mok: MOK password hash)" "mokutil (UKI_TRUST=mok, package mokutil)" command -v mokutil
    fi
    report swtpm "swtpm (package swtpm-tools)" command -v swtpm
    report "libvirt network $NET (active)" "libvirt network $NET or not active  (./build.sh net)" net_active
    report "libvirt pool $POOL (active)" "libvirt pool $POOL or not active  (./build.sh net)" pool_active
    local why rc=0
    why=$(nocow_problem "$DC_VM") || rc=$?
    case "$rc" in
        0) printf '  ok      pool dir copy-on-write disabled (or not btrfs)\n' ;;
        3) printf '  UNKNOWN %s\n' "$why" ;;
        *) printf '  BAD     %s\n' "$why"; missing=1 ;;
    esac
    local -a blocked
    mapfile -t blocked < <(qemu_blocked_all)
    if [ "${#blocked[@]}" -eq 0 ]; then
        printf '  ok      %s can enter the pool, media and stage directories\n' "${QEMU_USER:-libvirt-qemu}"
    else
        printf '  BAD     %s cannot enter:%s\n' "${QEMU_USER:-libvirt-qemu}" "$(printf ' %s' "${blocked[@]}")"
        printf '          Run: %s\n' "$(qemu_access_fix "${blocked[@]}")"
        missing=1
    fi
    verify_media || missing=1
    [ "$missing" -eq 0 ] || die "prerequisites missing"
    log "all prerequisites present"
}

cmd_fetch() {
    fetch_one "$WINSERVER_ISO" "$WINSERVER_URL"
    fetch_one "$VIRTIO_ISO"    "$VIRTIO_URL"
    fetch_one "$UBUNTU_ISO"    "$UBUNTU_URL"
    verify_media || die "media not verified. For NO-SUM: check the files, then ./build.sh pin"
    log "media ready"
}

cmd_pin() {
    pin_media
    verify_media || die "checksum mismatch: do not use this media"
    warn "commit checksums.sha256, so the next build checks against these sums"
}

cmd_net() {
    if "${VIRSH[@]}" net-info "$NET" >/dev/null 2>&1; then
        log "network $NET exists"
        net_active || "${VIRSH[@]}" net-start "$NET"
    else
        log "defining network $NET"
        local used; used=$(ip -4 route show "$NETWORK_ID" 2>/dev/null)
        [ -z "$used" ] || die "subnet $NETWORK_ID is in use ($used). Change DC_IP, NET_GW and CLIENT_IP in lab.env"
        mkdir -p "$STAGE"
        render libvirt/mld-lab.xml.tmpl "$STAGE/net.xml" xml
        "${VIRSH[@]}" net-define "$STAGE/net.xml"
        "${VIRSH[@]}" net-autostart "$NET"
        "${VIRSH[@]}" net-start "$NET"
    fi
    if "${VIRSH[@]}" pool-info "$POOL" >/dev/null 2>&1; then
        log "pool $POOL exists"
        pool_active || "${VIRSH[@]}" pool-start "$POOL"
    else
        log "defining pool $POOL at $POOL_DIR"
        mkdir -p "$POOL_DIR" "$MEDIA_DIR"
        "${VIRSH[@]}" pool-define-as "$POOL" dir --target "$POOL_DIR"
        "${VIRSH[@]}" pool-autostart "$POOL"
        "${VIRSH[@]}" pool-start "$POOL"
    fi
    local dir; dir=$(pool_path)
    if [ "$(stat -f -c %T "$dir" 2>/dev/null)" = btrfs ] && ! nocow "$dir"; then
        { chattr +C "$dir" 2>/dev/null || sudo -n chattr +C "$dir" 2>/dev/null; } \
            || die "chattr +C $dir failed. Run: sudo chattr +C $dir"
        log "copy-on-write disabled on $dir (new files only)"
    fi
}
