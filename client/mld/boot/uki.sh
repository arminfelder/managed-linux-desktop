#!/bin/bash
# Builds and signs one unified kernel image (UKI) per installed kernel, when UKI=1 in /etc/mld/config.env.
#
#   mld-uki [KVER]              build /boot/efi/EFI/Linux/mld-KVER.efi (default: newest kernel), then sync the boot entries
#   mld-uki all                 build the UKI of each installed kernel (after an initrd change), then sync
#   mld-uki sync                build only the missing UKIs, then sync (first boot, client resume)
#   mld-uki remove KVER         delete the UKI of KVER, then sync (/etc/kernel/postrm.d/zz-mld-uki)
#   mld-uki bootentry           sync the boot entries with the UKIs on the ESP (installer: curtin in-target)
#   mld-uki mok-state           UKI_TRUST=mok: print enrolled, pending or absent for the lab certificate
#   mld-uki mok-import          UKI_TRUST=mok: request MOK enrollment, password hash (crypt) on stdin
#   mld-uki mok-request         UKI_TRUST=mok: request MOK enrollment, mokutil asks for the one-time password
#   mld-uki keygen              make the signing key on this device, if there is none (real hardware)
#
# UKI_TRUST=db: the firmware db has the lab certificate. The firmware starts the UKI directly.
# UKI_TRUST=mok: the firmware db stays as delivered. shim starts the UKI and checks it against the MOK list.
# MokManager asks for the MOK password at the next boot. This step needs a person at the console.
#
# One boot entry per UKI ("MLD UKI KVER" or "MLD UKI (shim) KVER"), the newest kernel first in BootOrder.
# All UKIs have the same signature, so PCR 7 and a TPM2 seal are the same for each kernel.
# /etc/kernel/postinst.d/zz-mld-uki and postrm.d/zz-mld-uki run it when apt installs or removes a kernel.
# shim + grub stay as the last entry in both modes.
set -euo pipefail

CRT=/etc/mld/sb/db.crt
DER=/etc/mld/sb/db.der
KEY=/etc/mld/sb/db.key
ESP_DIR=/boot/efi/EFI/Linux
TMP=""
trap '[ -z "$TMP" ] || rm -rf "$TMP"' EXIT

die() { echo "$*" >&2; exit 1; }
# shellcheck source=/dev/null
load_config() { . /etc/mld/config.env; . /etc/mld/distro.sh; }

# Fedora also has /boot/vmlinuz-0-rescue-<machine-id>. It has no module directory, so dracut cannot use it.
kernels() {
    local f k
    for f in /boot/vmlinuz-*; do
        k=${f#/boot/vmlinuz-}
        if [ -e "$f" ] && [ -d "/lib/modules/$k" ]; then echo "$k"; fi
    done | sort -V
}

mok_state() {
    [ -r "$CRT" ] || { echo absent; return; }
    [ -f "$DER" ] || openssl x509 -in "$CRT" -outform DER -out "$DER"
    local out; out=$(mokutil --test-key "$DER" 2>&1 || true)
    case "$out" in
        *"already enrolled"*) echo enrolled ;;
        *"enrollment request"*) echo pending ;;
        *) echo absent ;;
    esac
}

# Real hardware: the key is made on the device and never leaves it. One MOK enrollment per device, so a stolen key
# signs boot images for this device only. The lab VMs get the lab key from the host (.stage/sb).
cmd_keygen() {
    [ -r "$KEY" ] && [ -r "$CRT" ] && return 0
    install -d -m 700 /etc/mld/sb
    ( umask 077
      openssl req -new -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
          -subj "/CN=MLD UKI signing $(hostname -s)/" -keyout "$KEY" -out "$CRT" 2>/dev/null )
    rm -f "$DER"
    echo "signing key made on this device: $CRT"
}

cmd_mok_request() {
    load_config
    [ "${UKI:-0}" = 1 ] && [ "${UKI_TRUST:-db}" = mok ] || die "needs UKI=1 and UKI_TRUST=mok"
    local state; state=$(mok_state)
    if [ "$state" != absent ]; then echo "signing certificate: $state"; return; fi
    echo "Type a one-time MOK password two times. MokManager asks for it at the next boot."
    mokutil --import "$DER"
    echo "signing certificate: $(mok_state)"
}

cmd_mok_import() {
    load_config
    [ "${UKI:-0}" = 1 ] && [ "${UKI_TRUST:-db}" = mok ] || die "needs UKI=1 and UKI_TRUST=mok"
    local state; state=$(mok_state)
    if [ "$state" != absent ]; then echo "lab certificate: $state"; return; fi
    TMP=$(mktemp -d)
    cat > "$TMP/hash"
    [ -s "$TMP/hash" ] || die "no password hash on stdin"
    mokutil --import "$DER" --hash-file "$TMP/hash"
    echo "lab certificate: $(mok_state)"
}

# Disk and partition number of the ESP. From /sys, not lsblk: in the installer chroot there is no udev database,
# so lsblk gives empty values.
esp_disk_part() {
    local src; src=$(basename "$(findmnt -no SOURCE /boot/efi)")
    printf '/dev/%s %s\n' "$(basename "$(readlink -f "/sys/class/block/$src/..")")" "$(cat "/sys/class/block/$src/partition")"
}

# Prints "NUM LABEL" for each boot entry whose label starts with "MLD UKI".
mld_entries() {
    efibootmgr | awk -F '\t' '/^Boot[0-9A-F][0-9A-F][0-9A-F][0-9A-F]\*? MLD UKI/ {
        n = substr($1, 5, 4); l = $1; sub(/^Boot[0-9A-F]+\*? /, "", l); sub(/ +$/, "", l); print n, l }'
}

cmd_bootentry() {
    load_config
    [ "${UKI:-0}" = 1 ] || return 0
    local prefix="MLD UKI" shim="" state disk part kver label num want order rest
    if [ "${UKI_TRUST:-db}" = mok ]; then
        # Without the MOK, shim refuses the UKI. The installer leaves shim + grub as the only entry.
        state=$(mok_state)
        if [ "$state" != enrolled ]; then echo "MOK $state: no UKI boot entry yet"; return; fi
        shim=$SHIM_EFI
        [ -f "$SHIM_FILE" ] || die "no $SHIM_FILE"
        prefix="MLD UKI (shim)"
    fi
    read -r disk part < <(esp_disk_part)

    want=$'\n'
    for kver in $(kernels); do
        if [ -f "$ESP_DIR/mld-$kver.efi" ]; then want+="$prefix $kver"$'\n'; fi
    done
    # Old entries: removed kernels, the other trust mode, and the single "MLD UKI" entry of older versions.
    while read -r num label; do
        [ -n "$num" ] || continue
        if [[ "$want" != *$'\n'"$label"$'\n'* ]]; then efibootmgr --quiet --bootnum "$num" --delete-bootnum; fi
    done < <(mld_entries)
    for kver in $(kernels); do
        [ -f "$ESP_DIR/mld-$kver.efi" ] || continue
        label="$prefix $kver"
        # No grep -q: with pipefail, an early grep exit can fail the pipeline and make a second entry.
        if mld_entries | cut -d' ' -f2- | grep -xF "$label" >/dev/null; then continue; fi
        if [ -n "$shim" ]; then
            # shim reads the second stage path from the first word of its load options.
            # efibootmgr adds no NUL. Without a space or NUL after the path, shim ignores it and starts grub.
            efibootmgr --quiet --create --disk "$disk" --part "$part" --label "$label" --loader "$shim" \
                --unicode "\\EFI\\Linux\\mld-$kver.efi "
        else
            efibootmgr --quiet --create --disk "$disk" --part "$part" --label "$label" \
                --loader "\\EFI\\Linux\\mld-$kver.efi"
        fi
    done

    # BootOrder: the UKI entries, newest kernel first, then the other entries in their old order.
    order=$(mld_entries | awk '{ print $NF, $1 }' | sort -V -r -k1,1 | awk '{ print $2 }' | paste -sd,)
    rest=$(efibootmgr | sed -n 's/^BootOrder: //p' | tr ',' '\n' | grep -vxF -f <(mld_entries | cut -d' ' -f1) | paste -sd, || true)
    [ -z "$order" ] || efibootmgr --quiet --bootorder "$order${rest:+,$rest}"
    efibootmgr | grep -E '^BootOrder|MLD UKI'
}

build_one() {
    local kver=$1 stub cmdline size avail
    [ -e "/boot/vmlinuz-$kver" ] || die "no /boot/vmlinuz-$kver"
    stub=$(ls /usr/lib/systemd/boot/efi/linuxx64.efi.stub 2>/dev/null || true)
    [ -n "$stub" ] || die "no systemd EFI stub (package systemd-boot-efi)"
    [ -r "$KEY" ] && [ -r "$CRT" ] || die "no signing key in /etc/mld/sb"
    # The lab VMs have a serial console: build.sh types the passphrase there. Real hardware shows only the screen.
    if [ "${CLIENT_TARGET:-vm}" = hw ]; then
        cmdline="root=UUID=$(findmnt -no UUID /) ro quiet splash"
    else
        cmdline="root=UUID=$(findmnt -no UUID /) ro splash console=tty0 console=ttyS0,115200n8"
    fi

    TMP=$(mktemp -d)
    dracut --force --quiet --uefi --uefi-stub "$stub" --kernel-cmdline "$cmdline" --kver "$kver" "$TMP/unsigned.efi"
    sbsign --key "$KEY" --cert "$CRT" --output "$TMP/mld.efi" "$TMP/unsigned.efi"
    sbverify --cert "$CRT" "$TMP/mld.efi" >/dev/null

    install -d "$ESP_DIR"
    size=$(stat -c %s "$TMP/mld.efi")
    avail=$(df -B1 --output=avail "$ESP_DIR" | tail -1)
    if [ -f "$ESP_DIR/mld-$kver.efi" ]; then avail=$(( avail + $(stat -c %s "$ESP_DIR/mld-$kver.efi") )); fi
    [ "$avail" -gt "$size" ] || die "ESP full: UKI $size bytes, free $avail bytes"
    # A copy, then a rename on the same file system: a crash leaves the old UKI or the new one, not half a file.
    cp "$TMP/mld.efi" "$ESP_DIR/.mld-$kver.efi.new"
    mv "$ESP_DIR/.mld-$kver.efi.new" "$ESP_DIR/mld-$kver.efi"
    rm -rf "$TMP"; TMP=""
    echo "UKI for $kver signed: $ESP_DIR/mld-$kver.efi"
}

# Deletes the UKIs without a kernel, and the single UKI of older versions. Run after the entry sync.
cleanup() {
    local f kver
    for f in "$ESP_DIR"/mld-*.efi; do
        [ -e "$f" ] || continue
        kver=${f##*/mld-}; kver=${kver%.efi}
        [ -e "/boot/vmlinuz-$kver" ] || { rm -f "$f"; echo "UKI $f removed: no kernel $kver"; }
    done
    rm -f "$ESP_DIR/mld.efi" "$ESP_DIR/mld-prev.efi" "$ESP_DIR"/.mld-*.efi.new
}

cmd_build() {
    load_config
    [ "${UKI:-0}" = 1 ] || return 0
    if [ "${CLIENT_TARGET:-vm}" = hw ]; then cmd_keygen; fi
    local kver
    case "${1:-}" in
        all) for kver in $(kernels); do build_one "$kver"; done ;;
        sync) for kver in $(kernels); do if [ ! -f "$ESP_DIR/mld-$kver.efi" ]; then build_one "$kver"; fi; done ;;
        "") kver=$(kernels | tail -1); [ -n "$kver" ] || die "no kernel in /boot"; build_one "$kver" ;;
        *) build_one "$1" ;;
    esac
    cmd_bootentry
    cleanup
}

cmd_remove() {
    load_config
    [ "${UKI:-0}" = 1 ] || return 0
    [ -n "${1:-}" ] || die "usage: mld-uki remove KVER"
    rm -f "$ESP_DIR/mld-$1.efi"
    cmd_bootentry
    cleanup
}

case "${1:-}" in
    mok-state) mok_state ;;
    mok-import) cmd_mok_import ;;
    mok-request) cmd_mok_request ;;
    keygen) cmd_keygen ;;
    bootentry) cmd_bootentry ;;
    remove) cmd_remove "${2:-}" ;;
    *) cmd_build "$@" ;;
esac
