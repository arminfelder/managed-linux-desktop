# Sourced by build.sh: the client VM (install, boot, unlock, first boot, MOK, FIDO2).
# shellcheck shell=bash

# install_list: "source target mode" lines of client/mld/install.list, without comments.
install_list() { awk '!/^[[:space:]]*#/ && NF == 3' "$HERE/client/mld/install.list"; }

# Boot and login screen images, made from BRAND_LOGO + BRAND_BG. They are not in git: install.list names them
# brand/logo.png and brand/background.png, and client_src finds them in $STAGE/brand.
brand_stage() {
    local logo="${BRAND_LOGO:-client/mld/brand/logo.svg}" d="$STAGE/brand" f
    [ -f "$logo" ] || die "BRAND_LOGO: $logo does not exist"
    [[ "$BRAND_BG" =~ ^#[0-9a-fA-F]{6}$ ]] || die "BRAND_BG must be #rrggbb, not '$BRAND_BG'"
    command -v magick >/dev/null || die "ImageMagick (magick) is necessary for the logo"
    mkdir -p "$d"
    magick -quiet -background none -density 96 "$logo" -resize '480x160>' -strip "PNG32:$d/logo.png" 2>/dev/null \
        || die "could not convert $logo"
    # 1920x1080, the logo at the bottom: the SDDM Breeze theme has the clock and the login box in the center.
    magick -quiet -size 1920x1080 "xc:$BRAND_BG" "$d/logo.png" -gravity south -geometry +0+80 -composite -strip \
        "PNG24:$d/background.png" || die "could not make the login background"
    # client resume sends each file base64 encoded in one virsh argument (limit 128 KiB).
    for f in logo.png background.png; do
        [ "$(stat -c %s "$d/$f")" -le 65536 ] || die "$d/$f is larger than 64 KiB: use a simpler logo"
    done
}
client_src() {
    case "$1" in
        brand/logo.png|brand/background.png) printf '%s\n' "$STAGE/$1" ;;
        *) printf '%s\n' "client/mld/$1" ;;
    esac
}

# Client config files rendered from lab.env. client iso puts them on CIDATA, client resume pushes them.
CLIENT_TEMPLATES="ad/krb5.conf:none ad/sssd.conf:none home/pam_mount.conf.xml:xml gpo/gpupdate.conf:none"
render_client_templates() {
    local t
    for t in $CLIENT_TEMPLATES; do
        mkdir -p "$1/$(dirname "${t%%:*}")"
        render "client/mld/${t%%:*}.tmpl" "$1/${t%%:*}" "${t#*:}"
    done
}

# Install image for real hardware: .stage/mld-hw.iso (USB stick: dd, or any ISO writer). One image with the
# autoinstall (/nocloud), the client files (/mld) and the offline join blobs (/odj, from client odj NAME...).
# No passwords: the installer asks for the identity and the storage (LVM + LUKS passphrase). The grub entry has no
# "autoinstall" word, so the installer asks before it erases a disk. UKI_TRUST=mok: the device makes its own signing
# key at the first boot (mld-uki keygen); mld-firstboot secure requests the MOK.
client_hw_iso() {
    [ -f "$UBUNTU_ISO" ] || die "missing $UBUNTU_ISO: ./build.sh fetch"
    [ "${UKI:-0}" != 1 ] || [ "$UKI_TRUST" = mok ] || die "real hardware has the vendor keys: use UKI=0 or UKI_TRUST=mok"
    python3 -c 'import yaml' 2>/dev/null || die "python3-yaml is necessary on the host"
    local h="$STAGE/hw" src n=0 f
    rm -rf "$h"; mkdir -p "$h/nocloud" "$h/mld" "$h/odj"
    ( umask 077
      # The lab template needs values for the secrets. The hardware autoinstall drops these keys.
      CLIENT_ADMIN_HASH='!' LUKS_PASSPHRASE=unused CLIENT_HOSTNAME=name-me \
          render client/user-data.tmpl "$h/user-data.lab" yaml )
    python3 "$HERE/lib/hw-user-data.py" "$h/user-data.lab" "$h/nocloud/user-data"
    rm -f "$h/user-data.lab"
    grep -q 'interactive-sections' "$h/nocloud/user-data" || die "hardware autoinstall not made"
    ! grep -qE 'password|LUKS|join-pass' "$h/nocloud/user-data" || die "the hardware autoinstall has a secret"
    printf 'instance-id: mld-hw-%s\n' "$(date -u +%Y%m%d%H%M%S)" > "$h/nocloud/meta-data"
    render_client_templates "$h/mld"
    brand_stage
    while read -r src _ _; do mkdir -p "$h/mld/$(dirname "$src")"; cp "$(client_src "$src")" "$h/mld/$src"; done < <(install_list)
    cp client/mld/install.list "$h/mld/"
    {
        local v
        for v in DOMAIN REALM DC_FQDN DC_IP LINUX_OU PROBE_USER ENROLL_TPM2 TPM2_PCRS UKI UKI_TRUST CIFS_HOME SNX_RS MACHINE_TOKEN_PIN CLIENT_DE CLIENT_ADMIN BRAND_BG CA_NAME PKI_ENROLL LINUX_GROUP DOMAIN_DN; do
            printf '%s=%q\n' "$v" "${!v:-}"
        done
        echo CLIENT_TARGET=hw
    } > "$h/mld/config.env"
    for f in "$STAGE"/odj/*.txt; do [ -e "$f" ] || continue; cp "$f" "$h/odj/"; n=$((n + 1)); done
    [ "$n" -gt 0 ] || warn "no offline join blobs in $STAGE/odj: each device needs mld-firstboot join FILE (or: client odj NAME, then hw-iso again)"

    xorriso -osirrox on -indev "$UBUNTU_ISO" -extract /boot/grub/grub.cfg "$h/grub.orig.cfg" 2>/dev/null
    chmod u+w "$h/grub.orig.cfg"
    # grub needs the ";" escaped. No "autoinstall": the installer asks for a confirmation before it changes a disk.
    sed -e '/^[[:space:]]*linux[[:space:]].*\/casper\/vmlinuz/ s| ---| ds=nocloud\\;s=/cdrom/nocloud/ ---|' \
        "$h/grub.orig.cfg" > "$h/grub.cfg"
    grep -q 'ds=nocloud\\;s=/cdrom/nocloud/' "$h/grub.cfg" || die "no casper/vmlinuz entry with ' ---' in grub.cfg"
    rm -f "$STAGE/mld-hw.iso"
    xorriso -indev "$UBUNTU_ISO" -outdev "$STAGE/mld-hw.iso" -map "$h/grub.cfg" /boot/grub/grub.cfg \
        -map "$h/nocloud" /nocloud -map "$h/mld" /mld -map "$h/odj" /odj -boot_image any replay 2>&1 | tail -2
    chmod 600 "$STAGE/mld-hw.iso"
    rm -rf "$h"
    log "$STAGE/mld-hw.iso ready: $n offline join blob(s). Write it to a USB stick (dd bs=4M of=/dev/sdX). The blobs are secrets."
}

# Lab Secure Boot signing key for the UKI. It stays in .stage/sb across client rebuilds.
SB_OWNER_GUID=6d6c6400-0000-4000-8000-6c6162756b69
sb_keys() {
    [ -f "$STAGE/sb/db.key" ] && [ -f "$STAGE/sb/db.crt" ] && return
    mkdir -p "$STAGE/sb"
    ( umask 077
      openssl req -quiet -new -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
          -subj "/CN=MLD lab UKI signing key/" -keyout "$STAGE/sb/db.key" -out "$STAGE/sb/db.crt" )
    log "lab Secure Boot key made: $STAGE/sb/db.crt"
}

# Writes the client NVRAM (qcow2). With UKI=1 and UKI_TRUST=db, the lab certificate goes into db, next to the Microsoft keys.
# UKI_TRUST=mok keeps the Microsoft keys only.
client_nvram() {
    local nv="$1" src="$OVMF_VARS"
    if [ "${UKI:-0}" = 1 ] && [ "$UKI_TRUST" = db ]; then
        command -v virt-fw-vars >/dev/null || die "UKI=1 needs virt-fw-vars (package python3-virt-firmware)"
        sb_keys
        virt-fw-vars --input "$OVMF_VARS" --output "$STAGE/client-vars.fd" \
            --add-db "$SB_OWNER_GUID" "$STAGE/sb/db.crt" >/dev/null
        src="$STAGE/client-vars.fd"
    fi
    rm -f "$nv"
    qemu-img convert -f raw -O qcow2 "$src" "$nv"
}

# Offline domain join blob for one computer name: .stage/odj/NAME.txt (mode 600). The DC makes the account in the
# Linux OU. The blob holds the password of this one computer account, no join password.
# REPLACE=1 deletes an existing account of this name in the Linux OU first (the device is new).
odj_provision() {
    local name="${1^^}" b64 f
    [[ "$name" =~ ^[A-Z0-9][A-Z0-9-]{0,14}$ ]] || die "computer name '$1': 1-15 characters, letters, digits, '-'"
    mkdir -p "$STAGE/odj"; chmod 700 "$STAGE/odj"
    f="$STAGE/odj/$name.txt"
    b64=$(guest_run dc dc/guest/odj-provision.ps1 "Machine=$name" "Replace=${REPLACE:-0}" | tr -d '\r\n') || die "djoin /provision $name failed"
    [ -n "$b64" ] || die "the DC returned no blob for $name"
    ( umask 077; base64 -d <<<"$b64" > "$f" ) || die "the blob for $name is not base64"
    log "offline join blob for $name: $f (secret: the password of the computer account)"
}

client_iso() {
    need_secrets CLIENT_ADMIN_PW LUKS_PASSPHRASE
    [ -f "$UBUNTU_ISO" ] || die "missing $UBUNTU_ISO: ./build.sh fetch"
    local c="$STAGE/cidata"
    rm -rf "$c"; mkdir -p "$c/mld"
    umask 077

    CLIENT_ADMIN_HASH=$(openssl passwd -6 -stdin <<<"$CLIENT_ADMIN_PW")
    export CLIENT_ADMIN_HASH
    render client/user-data.tmpl "$c/user-data" yaml
    printf 'instance-id: %s-%s\nlocal-hostname: %s\n' "$CLIENT_VM" "$(date -u +%s)" "$CLIENT_HOSTNAME" > "$c/meta-data"

    render_client_templates "$c/mld"
    brand_stage
    local src
    while read -r src _ _; do mkdir -p "$c/mld/$(dirname "$src")"; cp "$(client_src "$src")" "$c/mld/$src"; done < <(install_list)
    cp client/mld/install.list "$c/mld/"
    if [ "${UKI:-0}" = 1 ]; then
        sb_keys
        mkdir -p "$c/mld/sb"
        cp "$STAGE/sb/db.key" "$STAGE/sb/db.crt" "$c/mld/sb/"
    fi
    {
        local v
        for v in DOMAIN REALM DC_FQDN DC_IP JOIN_USER LINUX_OU PROBE_USER ENROLL_TPM2 TPM2_PCRS UKI UKI_TRUST CIFS_HOME SNX_RS MACHINE_TOKEN_PIN CLIENT_DE CLIENT_ADMIN BRAND_BG CA_NAME PKI_ENROLL LINUX_GROUP DOMAIN_DN; do
            printf '%s=%q\n' "$v" "${!v:-}"
        done
    } > "$c/mld/config.env"
    # A new client build is a new device: an account of the same name from an earlier build is replaced.
    REPLACE=1 odj_provision "$CLIENT_HOSTNAME"
    cp "$STAGE/odj/${CLIENT_HOSTNAME^^}.txt" "$c/mld/odj.txt"
    printf '%s' "$CLIENT_ADMIN_HASH" > "$c/mld/admin-hash"
    printf '%s' "$LUKS_PASSPHRASE" > "$c/mld/luks-pass"
    # libvirt can leave the old ISO owned by libvirt-qemu (mode 600). The directory is ours, so rm works.
    rm -f "$STAGE/cidata.iso"
    genisoimage -quiet -J -r -V CIDATA -o "$STAGE/cidata.iso" "$c"
    umask 022
    # libvirt dynamic_ownership gives the qemu user access while the VM runs. Other users cannot read it.
    chmod 600 "$STAGE/cidata.iso"
    log "cidata.iso ready (contains lab secrets, stays in .stage/)"

    # Only grub.cfg changes. shim, grub and the kernel stay signed, so Secure Boot also covers the install.
    log "remastering $(basename "$UBUNTU_ISO") with the autoinstall boot entry"
    rm -f "$STAGE/grub.orig.cfg" "$STAGE/grub.cfg" "$STAGE/ubuntu-autoinstall.iso"
    xorriso -osirrox on -indev "$UBUNTU_ISO" -extract /boot/grub/grub.cfg "$STAGE/grub.orig.cfg" 2>/dev/null
    chmod u+w "$STAGE/grub.orig.cfg"
    sed -e 's/^set timeout=.*/set timeout=1/' \
        -e '/^[[:space:]]*linux[[:space:]].*\/casper\/vmlinuz/ s| ---| autoinstall ds=nocloud ---|' \
        "$STAGE/grub.orig.cfg" > "$STAGE/grub.cfg"
    grep -q 'autoinstall ds=nocloud' "$STAGE/grub.cfg" \
        || die "no casper/vmlinuz entry with ' ---' in grub.cfg: the ISO layout changed"
    xorriso -indev "$UBUNTU_ISO" -outdev "$STAGE/ubuntu-autoinstall.iso" \
        -map "$STAGE/grub.cfg" /boot/grub/grub.cfg -boot_image any replay 2>&1 | tail -2
    log "ubuntu-autoinstall.iso ready"
}

client_eject_cdroms() {
    local t
    for t in $("${VIRSH[@]}" domblklist "$CLIENT_VM" --details | awk '$2 == "cdrom" { print $3 }'); do
        "${VIRSH[@]}" change-media "$CLIENT_VM" "$t" --eject --config >/dev/null 2>&1 || true
    done
}

client_vm() {
    require_qemu_access
    pool_refresh
    [ -f "$STAGE/ubuntu-autoinstall.iso" ] && [ -f "$STAGE/cidata.iso" ] || die "run ./build.sh client iso first"
    vm_exists "$CLIENT_VM" && die "VM '$CLIENT_VM' exists: ./build.sh client destroy first"
    require_no_orphan_disk "$CLIENT_VM"
    require_nocow "$CLIENT_VM"
    # libvirt makes internal snapshots of a pflash VM only with a qcow2 NVRAM. OVMF ships raw files only,
    # so the NVRAM is converted from the MS-key template. Firmware autoselection is off: it matches raw NVRAM only.
    local nv="$POOL_DIR/${CLIENT_VM}_VARS.qcow2"
    client_nvram "$nv"
    log "installing $CLIENT_VM (UEFI Secure Boot, MS keys, TPM 2.0 CRB). The install takes 15-40 min."
    # --noreboot: the VM stays off after the install. client_start then attaches the console before the boot,
    # so the passphrase prompt cannot appear before the watcher reads the console.
    virt-install \
        --connect "$LIBVIRT_URI" \
        --name "$CLIENT_VM" \
        --machine q35 \
        --boot "loader=$OVMF_CODE,loader.readonly=yes,loader.type=pflash,loader.secure=yes,nvram=$nv" \
        --xml ./os/nvram/@format=qcow2 \
        --features smm.state=on \
        --tpm backend.type=emulator,backend.version=2.0,model=tpm-crb \
        --vcpus "$CLIENT_VCPUS" \
        --memory "$CLIENT_RAM_MB" \
        --cpu host-passthrough \
        --disk "pool=$POOL,size=$CLIENT_DISK_GB,bus=virtio,format=qcow2,driver.discard=unmap" \
        --network "network=$NET,model=virtio,mac=$CLIENT_MAC" \
        --cdrom "$STAGE/ubuntu-autoinstall.iso" \
        --disk "path=$STAGE/cidata.iso,device=cdrom,readonly=on" \
        --os-variant "${CLIENT_OS_VARIANT:-$(pick_os_variant ubuntu26.04 ubuntu25.10 ubuntu25.04 ubuntu24.04 linux2024 linux2022)}" \
        --clock offset=utc \
        --graphics vnc,listen=127.0.0.1 \
        --video virtio \
        --serial pty \
        --channel unix,target.type=virtio,target.name=org.qemu.guest_agent.0 \
        --noautoconsole \
        --noreboot \
        --wait "${CLIENT_INSTALL_WAIT_MIN:-90}"
    "${VIRSH[@]}" domstate "$CLIENT_VM" | grep -q 'shut off' \
        || die "$CLIENT_VM still runs: the install did not finish. Check ./build.sh client screenshot"
    client_eject_cdroms
    if [ -n "${FIDO2_HOSTDEV:-}" ]; then client_fido2_attach; fi
    client_start
    log "Next: ./build.sh client wait"
}

client_console() {
    CONSOLE_LOG="$STAGE/client-console.log" python3 "$HERE/lib/console.py" "$LIBVIRT_URI" "$CLIENT_VM" "$@"
}

client_start() {
    require_qemu_access
    need_secrets LUKS_PASSPHRASE
    "${VIRSH[@]}" domstate "$CLIENT_VM" | grep -q 'shut off' || die "$CLIENT_VM is not shut off: use ./build.sh client unlock"
    log "booting $CLIENT_VM and typing the passphrase on the serial console (log: .stage/client-console.log)"
    client_console unlock start || die "unlock failed. Read .stage/client-console.log"
}

client_unlock() {
    need_secrets LUKS_PASSPHRASE
    client_console unlock || die "unlock failed. Read .stage/client-console.log"
}

client_status() {
    GUEST_EXEC_TIMEOUT=30 guest_run client client/guest/status.sh 2>/dev/null
}

client_log() { ./guest-exec.sh client "tail -n ${1:-60} /var/log/mld-firstboot.log"; }

client_wait() {
    local deadline=$(( $(date +%s) + 45*60 )) last="" s phase
    log "waiting for client first-boot provisioning (up to 45 min)"
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if s=$(client_status); then
            if [ -n "$(json_get failed <<<"$s")" ]; then
                warn "first boot FAILED: $(json_get failed <<<"$s")"
                client_log 40 || true
                die "fix the cause, then run /usr/local/sbin/mld-firstboot in the guest again, or destroy + vm"
            fi
            if [ -n "$(json_get "done" <<<"$s")" ]; then log "client first boot DONE at $(json_get "done" <<<"$s")"; return 0; fi
            phase=$(json_get phase <<<"$s")
            if [ "$phase" != "$last" ]; then printf '\n'; log "phase ${phase:-<not started>}"; last="$phase"; fi
        fi
        printf '.'
        sleep 15
    done
    die "timed out. Check ./build.sh client log"
}

# client_reboot_console MODE: attaches the console watcher, then reboots the guest. MODE as in lib/console.py.
client_reboot_console() {
    client_console "$1" &
    local watcher=$!
    sleep 3
    GUEST_EXEC_TIMEOUT=10 ./guest-exec.sh client 'systemctl reboot' >/dev/null 2>&1 || true
    wait "$watcher"
}

# KEY=VALUE lines: MOK state, firmware db, BootCurrent label, UKI boot.
client_boot_facts() { guest_run client client/guest/boot-facts.sh; }

# The real MOK flow: the OS requests the enrollment, a person confirms it in MokManager at the next boot.
# Here console.py types the confirmation and the MOK password on the serial console.
client_mok_enroll() {
    [ "${UKI:-0}" = 1 ] && [ "$UKI_TRUST" = mok ] || die "client mok-enroll needs UKI=1 and UKI_TRUST=mok"
    need_secrets LUKS_PASSPHRASE MOK_PASSWORD
    command -v mokutil >/dev/null || die "mokutil missing on the host (package mokutil)"
    local facts state hash
    state=$(./guest-exec.sh client '/usr/local/sbin/mld-uki mok-state') || die "cannot read the MOK state"
    if [ "$state" != enrolled ]; then
        # Only the crypt hash goes to the guest. MokManager compares the typed password with it.
        hash=$(mokutil --generate-hash="$MOK_PASSWORD") || die "mokutil --generate-hash failed"
        ./guest-exec.sh client "/usr/local/sbin/mld-uki mok-import <<'EOF'
$hash
EOF" || die "mokutil --import failed in the guest"
        log "MOK request set. Rebooting: console.py confirms it in MokManager, then types the LUKS passphrase"
        client_reboot_console mok || die "MokManager step failed. Read .stage/client-console.log"
        state=$(./guest-exec.sh client '/usr/local/sbin/mld-uki mok-state') || die "cannot read the MOK state"
        [ "$state" = enrolled ] || die "lab certificate after MokManager: $state"
    fi
    log "lab certificate is in the MOK list"
    ./guest-exec.sh client '/usr/local/sbin/mld-uki bootentry' || die "boot entry for shim + UKI failed"
    # A second run (setup after an interruption): the client can run from the shim + UKI path already, sealed to TPM2.
    # Then no reboot: console.py would wait for a passphrase prompt that the TPM2 token answers.
    facts=$(client_boot_facts) || die "cannot query the guest"
    if grep -qx 'uki_booted=yes' <<<"$facts" && grep -q '^boot_entry=MLD UKI (shim) ' <<<"$facts"; then
        log "already booted through shim + UKI: no reboot"
    else
        log "rebooting through shim into the UKI (passphrase prompt expected: no TPM2 keyslot for this path yet)"
        client_reboot_console expect-prompt || die "boot through shim + UKI failed. Read .stage/client-console.log"
        facts=$(client_boot_facts) || die "cannot query the guest"
        grep -qx 'uki_booted=yes' <<<"$facts" || die "the boot did not come from the UKI: $(tr '\n' ' ' <<<"$facts")"
        grep -q '^boot_entry=MLD UKI (shim) ' <<<"$facts" || die "BootCurrent is not 'MLD UKI (shim) <kernel>': $(tr '\n' ' ' <<<"$facts")"
    fi
    log "booted: shim -> UKI ($(tr '\n' ' ' <<<"$facts"))"
    if [ "${ENROLL_TPM2:-0}" = 1 ] && ./guest-exec.sh client 'test -f /var/lib/mld/tpm2.done' >/dev/null 2>&1; then
        log "TPM2 is sealed already (/var/lib/mld/tpm2.done)"
    elif [ "${ENROLL_TPM2:-0}" = 1 ]; then
        GUEST_EXEC_TIMEOUT=600 guest_run client client/guest/firstboot-sub.sh \
            SUB=enroll-tpm2 "PASSWORD=$LUKS_PASSPHRASE" PIN= TAIL=8 || die "TPM2 enrollment failed"
        log "TPM2 sealed to PCR $TPM2_PCRS of the shim + UKI path. Test with: ./build.sh client reboot-test"
    fi
}

client_fido2_attach() {
    [[ "${FIDO2_HOSTDEV:-}" =~ ^([0-9a-fA-F]{4}):([0-9a-fA-F]{4})$ ]] || die "FIDO2_HOSTDEV must be vendor:product, for example 1050:0407"
    local xml="$STAGE/fido2-hostdev.xml" flags=(--config)
    cat > "$xml" <<EOF
<hostdev mode='subsystem' type='usb' managed='yes'>
  <source startupPolicy='optional'>
    <vendor id='0x${BASH_REMATCH[1]}'/>
    <product id='0x${BASH_REMATCH[2]}'/>
  </source>
</hostdev>
EOF
    if grep -q "<vendor id='0x${BASH_REMATCH[1]}'/>" <<<"$("${VIRSH[@]}" dumpxml --inactive "$CLIENT_VM")"; then
        log "FIDO2 key ${FIDO2_HOSTDEV} is already in the config"; return 0
    fi
    "${VIRSH[@]}" domstate "$CLIENT_VM" | grep -q running && flags+=(--live)
    "${VIRSH[@]}" attach-device "$CLIENT_VM" "$xml" "${flags[@]}"
    log "FIDO2 key ${FIDO2_HOSTDEV} attached (startupPolicy optional: the VM boots without the key)"
}

client_enroll_fido2() {
    [ -n "${FIDO2_HOSTDEV:-}" ] || die "set FIDO2_HOSTDEV in lab.env"
    need_secrets LUKS_PASSPHRASE
    client_fido2_attach
    warn "touch the FIDO2 key when it blinks (twice: enrollment and the check)"
    local pin_flag=no
    [ -z "${FIDO2_PIN:-}" ] || pin_flag=yes
    GUEST_EXEC_TIMEOUT=180 guest_run client client/guest/firstboot-sub.sh \
        "SUB=enroll-fido2 $pin_flag" "PASSWORD=$LUKS_PASSPHRASE" "PIN=${FIDO2_PIN:-}" TAIL=15 \
        || die "FIDO2 enrollment failed"
    log "FIDO2 enrolled. Test with: ./build.sh client reboot-test"
}

# Pushes the files in client/mld/install.list, the rendered templates and the current config.env values, then runs first boot again.
# The phases are idempotent: done phases are skipped through their marker files.
client_resume() {
    need_secrets CLIENT_ADMIN_PW
    local snippet="set -e" src dst mode v hash
    brand_stage
    while read -r src dst mode; do
        snippet+=$'\n'"mkdir -p /etc/mld/$(dirname "$src"); echo '$(base64 -w0 "$(client_src "$src")")' | base64 -d > /etc/mld/$src"
        [ "$dst" = - ] || snippet+=$'\n'"install -D -m $mode /etc/mld/$src $dst"
        # The snippet goes to virsh as one argument, base64 encoded again. Linux limits one argument to 128 KiB.
        if [ "${#snippet}" -gt 60000 ]; then
            ./guest-exec.sh client "$snippet" >/dev/null || die "could not copy the client files to the guest"
            snippet="set -e"
        fi
    done < <(install_list)
    local tdir t
    tdir=$(mktemp -d); render_client_templates "$tdir"
    for t in $CLIENT_TEMPLATES; do
        snippet+=$'\n'"mkdir -p /etc/mld/$(dirname "${t%%:*}"); echo '$(base64 -w0 "$tdir/${t%%:*}")' | base64 -d > /etc/mld/${t%%:*}; chmod 600 /etc/mld/${t%%:*}"
    done
    rm -rf "$tdir"
    # For phase_admin_pw: a client from before the fix has an empty admin password (cloud-init passwd -d).
    hash=$(openssl passwd -6 -stdin <<<"$CLIENT_ADMIN_PW")
    snippet+=$'\n'"echo '$(printf '%s' "$hash" | base64 -w0)' | base64 -d > /etc/mld/admin-hash; chmod 600 /etc/mld/admin-hash"
    snippet+=$'\n'"systemctl daemon-reload"
    for v in DC_IP CIFS_HOME SNX_RS MACHINE_TOKEN_PIN CLIENT_DE CLIENT_ADMIN BRAND_BG CA_NAME PKI_ENROLL LINUX_GROUP DOMAIN_DN UKI_TRUST; do
        snippet+=$'\n'"sed -i '/^$v=/d' /etc/mld/config.env; printf '%s\\n' $(printf '%q' "$v=${!v:-}") >> /etc/mld/config.env"
    done
    # Done phases are skipped by their markers. DONE goes too, so changed settings are applied.
    snippet+=$'\n'"rm -f /var/lib/mld/FAILED /var/lib/mld/DONE
systemctl reset-failed mld-firstboot.service || true
systemctl restart --no-block mld-firstboot.service
echo 'mld-firstboot restarted'"
    ./guest-exec.sh client "$snippet" || die "could not resume first boot in the client"
    log "first boot restarted. Next: ./build.sh client wait"
}

# For a client made before the qcow2 NVRAM change. The VM must be shut off. Needs sudo: libvirt owns the old NVRAM.
client_nvram_qcow2() {
    "${VIRSH[@]}" domstate "$CLIENT_VM" | grep -q 'shut off' || die "shut down $CLIENT_VM first: virsh shutdown $CLIENT_VM"
    local xml old nv="$POOL_DIR/${CLIENT_VM}_VARS.qcow2"
    xml=$("${VIRSH[@]}" dumpxml --inactive "$CLIENT_VM")
    old=$(sed -n 's:.*<nvram[^>]*>\(.*\)</nvram>.*:\1:p' <<<"$xml" | head -1)
    [ -n "$old" ] || die "no NVRAM path in the domain XML"
    grep -q "<nvram[^>]*format=.qcow2" <<<"$xml" && { log "NVRAM is qcow2 already: $old"; return; }
    sudo qemu-img convert -f raw -O qcow2 "$old" "$nv"
    sudo chown "$(id -u):$(id -g)" "$nv"
    printf '%s\n' "$xml" > "$STAGE/client-domain.in.xml"
    python3 - "$nv" "$OVMF_CODE" "$STAGE/client-domain.in.xml" > "$STAGE/client-domain.xml" <<'PY'
import sys, xml.etree.ElementTree as ET
nv, code, src = sys.argv[1:4]
root = ET.parse(src).getroot()
os_ = root.find("os")
os_.attrib.pop("firmware", None)
fw = os_.find("firmware")
if fw is not None:
    os_.remove(fw)
loader = os_.find("loader")
if loader is None:
    loader = ET.SubElement(os_, "loader")
loader.text = loader.text or code
loader.attrib.update({"readonly": "yes", "type": "pflash", "secure": "yes"})
nvram = os_.find("nvram")
nvram.text = nv
nvram.attrib = {"format": "qcow2"}
# A secure pflash loader needs SMM. Autoselection added it only to the live definition.
feats = root.find("features")
if feats is None:
    feats = ET.SubElement(root, "features")
if feats.find("smm") is None:
    ET.SubElement(feats, "smm", {"state": "on"})
print(ET.tostring(root, encoding="unicode"))
PY
    "${VIRSH[@]}" define "$STAGE/client-domain.xml" >/dev/null
    log "NVRAM converted to $nv (qcow2). The old file stays: $old"
}

# Runs CMD over ssh as the probe user (AD password login, so the session has a Kerberos ticket).
client_ssh_user() {
    command -v sshpass >/dev/null 2>&1 || die "sshpass missing"
    need_secrets LAB_USER_PW
    SSHPASS="$LAB_USER_PW" sshpass -e ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o PreferredAuthentications=password,keyboard-interactive -o LogLevel=ERROR \
        "$PROBE_USER@$CLIENT_IP" "$1"
}

# Sets the local admin password on the client to CLIENT_ADMIN_PW from lab.env (root through the guest agent).
client_set_admin_password() {
    need_secrets CLIENT_ADMIN_PW
    local u="${CLIENT_ADMIN:-labadmin}"
    guest_run client client/guest/set-admin-password.sh "ADMIN_USER=$u" "ADMIN_PW=$CLIENT_ADMIN_PW" \
        || die "could not set the password of $u"
    log "password of $u set from CLIENT_ADMIN_PW"
}
