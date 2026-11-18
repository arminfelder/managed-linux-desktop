#!/usr/bin/env bash
# Host render tests. No libvirt: guest-exec.sh and virsh are stubs.
# Usage: tests/render-test.sh [--record-baseline] [ubuntu|fedora|freeipa|all] [TEST...]
# No -e: the harness continues after a failed test and counts FAILS. lint: disable-file=sh-strict-mode
set -uo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILS=0

t_ok()   { echo "ok $1"; }
t_fail() { echo "FAIL $1: $2"; FAILS=$((FAILS + 1)); }
t_skip() { echo "skip $1: $2"; }

iso_ls()  { xorriso -indev "$1" -find / 2>/dev/null | LC_ALL=C sort; }
iso_cat() {
    local t; t=$(mktemp "$TMPDIR/isocat.XXXX")
    xorriso -osirrox on -indev "$1" -extract "$2" "$t" >/dev/null 2>&1 && cat "$t"
    rm -f "$t"
}

make_copy() {
    COPY=$(mktemp -d "${TMPDIR:-/tmp}/mld-render.XXXX")
    ( cd "$SRC" && { git ls-files -z; git ls-files -z --others --exclude-standard -- tests docs; } \
        | sort -zu | xargs -0 -I{} cp --parents -p {} "$COPY" ) 2>/dev/null
    [ -x "$COPY/build.sh" ] || { echo "copy failed: no executable build.sh in $COPY" >&2; exit 1; }
    rm -f "$COPY/lab.env"
    [ "${KEEP:-0}" = 1 ] || trap 'rm -rf "$COPY"' EXIT
    cat > "$COPY/guest-exec.sh" <<'STUB'
#!/usr/bin/env bash
role="${1:-}"; snippet="${2:-}"
log="$(dirname "$0")/.stub-calls.log"
inst=no; case "$snippet" in *"install -D"*) inst=yes ;; esac
printf '%s | %s | install-D=%s\n' "$role" "$(printf '%s' "$snippet" | head -n1)" "$inst" >> "$log"
printf '%s\n--- end\n' "$snippet" >> "$log.full"
case "$snippet" in
    *odj-provision*|*"djoin /provision"*) printf '%s' ODJ-TEST-BLOB | base64 ;;
    *"/etc/os-release"*) echo "ID=${STUB_OS_ID:-ubuntu}" ;;
    *"Marker 'DONE'"*) printf '{"phase":"9","done":"stub","failed":"","utc":%s}\n' "$(date -u +%s)" ;;
    *read_marker*) printf '{"phase":"5","done":"stub","failed":"","utc":%s}\n' "$(date -u +%s)" ;;
esac
exit 0
STUB
    chmod +x "$COPY/guest-exec.sh"
    # dc_ready: the DC VM exists and runs.
    mkdir -p "$COPY/.bin"
    cat > "$COPY/.bin/virsh" <<'STUB'
#!/usr/bin/env bash
case " $* " in *" domstate "*) echo running ;; esac
exit 0
STUB
    chmod +x "$COPY/.bin/virsh"
    export PATH="$COPY/.bin:$PATH"
    mkdir -p "$COPY/iso" "$COPY/.stage"
    write_lab
    make_ubuntu_iso "$COPY/iso/ubuntu.iso"
    make_fedora_iso "$COPY/iso/fedora.iso"
}

write_lab() {
    sed -e 's/=CHANGE-ME$/=Test-Secret-1/' \
        -e 's/^LUKS_PASSPHRASE=.*/LUKS_PASSPHRASE=test-luks-pass/' \
        -e 's/^CLIENT_ADMIN_PW=.*/CLIENT_ADMIN_PW=Test-Admin-Pw1/' \
        -e "s|^UBUNTU_ISO=.*|UBUNTU_ISO=$COPY/iso/ubuntu.iso|" \
        -e "s|^FEDORA_ISO=.*|FEDORA_ISO=$COPY/iso/fedora.iso|" \
        "$SRC/env.example" > "$COPY/lab.env"
}

# set_lab NAME VALUE: replaces or appends NAME in the test lab.env. Empty VALUE deletes the line.
set_lab() {
    sed -i "/^$1=/d" "$COPY/lab.env"
    [ -z "$2" ] || printf '%s=%s\n' "$1" "$2" >> "$COPY/lab.env"
}

build_in_copy() {
    ( cd "$COPY" && ./build.sh "$@" >"$COPY/.out.log" 2>"$COPY/.err.log" )
}

make_ubuntu_iso() {
    local d; d=$(mktemp -d "$TMPDIR/isosrc.XXXX")
    mkdir -p "$d/boot/grub"
    cat > "$d/boot/grub/grub.cfg" <<'G'
set timeout=30
menuentry "Try or Install Ubuntu Server" {
	set gfxpayload=keep
	linux	/casper/vmlinuz ---
	initrd	/casper/initrd
}
G
    xorriso -as mkisofs -quiet -V UBUNTU-FAKE -o "$1" "$d" >/dev/null 2>&1
    rm -rf "$d"
}

make_fedora_iso() {
    local d; d=$(mktemp -d "$TMPDIR/isosrc.XXXX")
    mkdir -p "$d/EFI/BOOT" "$d/boot/grub2"
    local l='	linuxefi /images/pxeboot/vmlinuz inst.stage2=hd:LABEL=Fedora-E-dvd-x86_64-45 quiet'
    local fmt='set default="1"\nset timeout=60\n'
    fmt+='menuentry "Install Fedora" {\n%s\n	initrdefi /images/pxeboot/initrd.img\n}\n'
    fmt+='menuentry "Test this media & install Fedora" {\n%s rd.live.check\n	initrdefi /images/pxeboot/initrd.img\n}\n'
    # shellcheck disable=SC2059
    printf "$fmt" "$l" "$l" > "$d/EFI/BOOT/grub.cfg"
    cp "$d/EFI/BOOT/grub.cfg" "$d/boot/grub2/grub.cfg"
    mkdir -p "$d/images/pxeboot" "$d/isolinux"
    head -c 4096 /dev/zero > "$d/isolinux/isolinux.bin"
    truncate -s 2M "$d/images/efiboot.img"
    mformat -i "$d/images/efiboot.img" -F ::
    mmd -i "$d/images/efiboot.img" ::/EFI ::/EFI/BOOT
    mcopy -i "$d/images/efiboot.img" "$d/EFI/BOOT/grub.cfg" ::/EFI/BOOT/grub.cfg
    cp "$d/images/efiboot.img" "$d/../efiboot-$$.img"
    xorriso -as mkisofs -quiet -V Fedora-E-dvd-x86_64-45 -o "$1" \
        -b isolinux/isolinux.bin -no-emul-boot -boot-load-size 4 -boot-info-table \
        -eltorito-alt-boot -e --interval:appended_partition_2:all:: -no-emul-boot \
        -partition_offset 16 -append_partition 2 0xef "$d/../efiboot-$$.img" -appended_part_as_gpt \
        "$d" >/dev/null 2>&1
    rm -f "$d/../efiboot-$$.img"
    rm -rf "$d"
}

render_ubuntu() {
    ( cd "$COPY" && ./build.sh client iso >"$COPY/.render-ubuntu.log" 2>&1 ) || {
        tail -n 20 "$COPY/.render-ubuntu.log" >&2; return 1; }
}

# The password hash has a random salt, instance-id has a timestamp.
norm_user_data() {
    sed -E -e 's/^([[:space:]]*password:).*/\1 HASH-NORMALISED/' -e '/instance-id/d' "$1"
}

ubuntu_artifacts() {
    local out="$1"
    mkdir -p "$out"
    norm_user_data "$COPY/.stage/cidata/user-data" > "$out/user-data"
    iso_ls "$COPY/.stage/cidata.iso" > "$out/cidata.ls"
    cp "$COPY/.stage/grub.cfg" "$out/grub.cfg"
    cp "$COPY/.stage/cidata/mld/install.list" "$out/install.list"
    grep -v '^CLIENT_DISTRO=' "$COPY/.stage/cidata/mld/config.env" > "$out/config.env"
}

ubuntu_baseline_unchanged() {
    local n=ubuntu_baseline_unchanged b="$SRC/tests/baseline/ubuntu"
    [ -d "$b" ] || { t_fail $n "no baseline: run --record-baseline"; return; }
    write_lab
    render_ubuntu || { t_fail $n "render failed"; return; }
    ubuntu_artifacts "$COPY/cur"
    local f
    for f in user-data cidata.ls grub.cfg install.list config.env; do
        diff -u "$b/$f" "$COPY/cur/$f" >&2 || { t_fail $n "$f differs"; return; }
    done
    t_ok $n
}

record_baseline() {
    make_copy
    render_ubuntu || { echo "render failed" >&2; exit 1; }
    rm -rf "$SRC/tests/baseline/ubuntu"
    ubuntu_artifacts "$SRC/tests/baseline/ubuntu"
    local f
    for f in "$SRC"/tests/baseline/ubuntu/*; do
        [ -s "$f" ] || {
            echo "empty artifact $f: baseline not usable" >&2; rm -rf "$SRC/tests/baseline/ubuntu"; exit 1; }
    done
    echo "baseline recorded in tests/baseline/ubuntu"
}

distro_default_ubuntu() {
    local n=distro_default_ubuntu
    write_lab; set_lab CLIENT_DISTRO ""
    build_in_copy client iso || { tail -n 5 "$COPY/.err.log" >&2; t_fail $n "client iso failed"; return; }
    grep -qx 'CLIENT_DISTRO=ubuntu' "$COPY/.stage/cidata/mld/config.env" && t_ok $n \
        || t_fail $n "config.env has no CLIENT_DISTRO=ubuntu"
}

distro_fedora_config() {
    local n=distro_fedora_config
    write_lab; set_lab CLIENT_DISTRO fedora; set_lab CLIENT_DE gnome
    build_in_copy client iso
    local cfg="$COPY/.stage/cidata/mld/config.env"
    [ -f "$COPY/.stage/cidata/ks.cfg" ] || { t_fail $n "no ks.cfg in CIDATA"; return; }
    grep -qx 'CLIENT_DISTRO=fedora' "$cfg" || { t_fail $n "config.env has no CLIENT_DISTRO=fedora"; return; }
    local out
    out=$(cd "$COPY" && HERE=$COPY STAGE=$COPY/.stage && set -a && . ./lab.env && set +a \
        && die() { echo "$*" >&2; exit 1; } \
        && . ./lib/config.sh && echo "$CLIENT_DM_UNIT $CLIENT_DESKTOP $CLIENT_DM $CLIENT_ISO $CLIENT_INSTALL_ISO") \
        || { t_fail $n "config.sh did not load"; return; }
    [ "$out" = "gdm.service workstation-product-environment gdm $COPY/iso/fedora.iso $COPY/.stage/fedora-ks.iso" ] \
        && t_ok $n || t_fail $n "derived values: $out"
}

distro_invalid() {
    local n=distro_invalid
    write_lab; set_lab CLIENT_DISTRO arch
    if build_in_copy client iso; then t_fail $n "exit 0"; return; fi
    grep -q 'CLIENT_DISTRO must be ubuntu or fedora' "$COPY/.err.log" && t_ok $n \
        || t_fail $n "no message: $(tail -n 2 "$COPY/.err.log")"
}

resume_distro_mismatch() {
    local n=resume_distro_mismatch
    write_lab; set_lab CLIENT_DISTRO fedora
    rm -f "$COPY/.stub-calls.log"
    if ( cd "$COPY" && STUB_OS_ID=ubuntu ./build.sh client resume >"$COPY/.out.log" 2>"$COPY/.err.log" ); then
        t_fail $n "exit 0"; return; fi
    grep -q 'build the client again' "$COPY/.err.log" \
        || { t_fail $n "no message: $(tail -n 2 "$COPY/.err.log")"; return; }
    [ -s "$COPY/.stub-calls.log" ] || { t_fail $n "stub not called: the os-id check did not run"; return; }
    ! grep -q 'install-D=yes' "$COPY/.stub-calls.log" && t_ok $n || t_fail $n "a file was pushed before the check"
}

installlist_filter() {
    local n=installlist_filter c="$COPY/.stage/cidata/mld"
    write_lab; set_lab CLIENT_DISTRO fedora; set_lab CLIENT_DE gnome
    build_in_copy client iso
    [ -f "$c/distro.sh" ] || { t_fail $n "fedora CIDATA has no mld/distro.sh"; return; }
    [ ! -e "$c/apps/mozilla.sources" ] || { t_fail $n "fedora CIDATA has apps/mozilla.sources"; return; }
    awk '!/^[[:space:]]*#/ && NF != 3 { bad = 1 } END { exit bad }' "$c/install.list" \
        || { t_fail $n "fedora install.list has a line with other than 3 columns"; return; }
    grep -q '^distro.sh ' "$c/install.list" || { t_fail $n "fedora install.list has no distro.sh"; return; }
    ! grep -q 'mozilla.sources' "$c/install.list" || { t_fail $n "fedora install.list has mozilla.sources"; return; }
    write_lab
    render_ubuntu || { t_fail $n "ubuntu render failed"; return; }
    c="$COPY/.stage/cidata/mld"
    [ -f "$c/apps/mozilla.sources" ] || { t_fail $n "ubuntu CIDATA has no apps/mozilla.sources"; return; }
    [ ! -e "$c/selinux" ] || { t_fail $n "ubuntu CIDATA has selinux/"; return; }
    awk '!/^[[:space:]]*#/ && NF != 3 { bad = 1 } END { exit bad }' "$c/install.list" \
        || { t_fail $n "ubuntu install.list has a line with other than 3 columns"; return; }
    grep -q '^distro.sh ' "$c/install.list" || { t_fail $n "ubuntu install.list has no distro.sh"; return; }
    local want; want=$(tr -s ' ' < "$SRC/tests/baseline/ubuntu/install.list" | sort)
    [ "$(tr -s ' ' < "$c/install.list" | sort)" = "$want" ] && t_ok $n \
        || t_fail $n "ubuntu install.list differs from the baseline"
}

distro_sh_functions() {
    local n=distro_sh_functions out
    out=$(set +eu; export CLIENT_DISTRO=fedora; . "$SRC/client/mld/distro.sh"
        initrd_path 6.17.1-300.fc45.x86_64
        echo "$SHIM_EFI $SHIM_FILE $PKCS11_DIR $BOOT_LABEL_RE"; echo "$PAM_AUTH_FILES $SSH_UNIT")
    [ "$out" = '/boot/initramfs-6.17.1-300.fc45.x86_64.img
\EFI\fedora\shimx64.efi /boot/efi/EFI/fedora/shimx64.efi /usr/lib64/pkcs11 fedora
/etc/pam.d/system-auth /etc/pam.d/password-auth sshd.service' ] || { t_fail $n "fedora: $out"; return; }
    out=$(set +eu; export CLIENT_DISTRO=ubuntu; . "$SRC/client/mld/distro.sh"
        initrd_path 7.0.0-43-generic; echo "$SHIM_EFI $PKCS11_DIR $PAM_AUTH_FILES $SSH_UNIT")
    [ "$out" = '/boot/initrd.img-7.0.0-43-generic
\EFI\ubuntu\shimx64.efi /usr/lib/x86_64-linux-gnu/pkcs11 /etc/pam.d/common-auth ssh.service' ] \
        || { t_fail $n "ubuntu: $out"; return; }
    local b; b=$(mktemp -d "$TMPDIR/ca.XXXX")
    printf '#!/bin/sh\necho "$(basename "$0") $*" >> "%s/log"\n' "$b" > "$b/update-ca-certificates"
    cp "$b/update-ca-certificates" "$b/update-ca-trust"; chmod +x "$b"/update-ca-*
    out=$(set +eu; PATH="$b:$PATH"; export CLIENT_DISTRO=ubuntu; . "$SRC/client/mld/distro.sh"
        echo "$CA_ANCHOR_DIR $CA_ANCHOR_PREFIX"; ca_trust_update; cat "$b/log")
    [ "$out" = '/usr/local/share/ca-certificates/mld 
update-ca-certificates ' ] || { t_fail $n "ubuntu CA: $out"; rm -rf "$b"; return; }
    out=$(set +eu; PATH="$b:$PATH"; export CLIENT_DISTRO=fedora; . "$SRC/client/mld/distro.sh"
        echo "$CA_ANCHOR_DIR $CA_ANCHOR_PREFIX"; ca_trust_update; tail -n1 "$b/log")
    rm -rf "$b"
    [ "$out" = '/etc/pki/ca-trust/source/anchors mld-
update-ca-trust extract' ] || { t_fail $n "fedora CA: $out"; return; }
    out=$(set +eu; unset CLIENT_DISTRO; . "$SRC/client/mld/distro.sh"; echo "$BOOT_LABEL_RE")
    [ "$out" = ubuntu ] || { t_fail $n "default is not ubuntu: $out"; return; }
    out=$(set -Eeuo pipefail; trap 'echo ERRTRAP' ERR; export CLIENT_DISTRO=ubuntu; . "$SRC/client/mld/distro.sh"
        pkg_installed no-such-pkg-xyz || true; v=$(pkg_version no-such-pkg-xyz); echo "[$v]"
        pkg_install; pkg_purge; echo done)
    [ "$out" = "[]
done" ] && t_ok $n || t_fail $n "strict mode: $out"
}

fedora_render() {
    write_lab; set_lab CLIENT_DISTRO fedora; set_lab CLIENT_DE gnome
    build_in_copy client iso || { tail -n 5 "$COPY/.err.log" >&2; return 1; }
}

ks_render() {
    local n=ks_render k="$COPY/.stage/cidata/ks.cfg"
    fedora_render || { t_fail $n "client iso failed"; return; }
    iso_ls "$COPY/.stage/cidata.iso" | grep -qx "'/ks.cfg'" || { t_fail $n "cidata.iso has no /ks.cfg"; return; }
    [ ! -e "$COPY/.stage/cidata/user-data" ] || { t_fail $n "fedora CIDATA has user-data"; return; }
    [ "$(grep -c '^selinux --enforcing$' "$k")" = 1 ] || { t_fail $n "selinux line"; return; }
    grep -q -- '--luks-version=luks2' "$k" || { t_fail $n "no luks2"; return; }
    grep -q '^@^workstation-product-environment$' "$k" || { t_fail $n "no desktop environment line"; return; }
    grep -q '^network .*--ipv4-ignore-auto-dns' "$k" && grep -q '^network .*--ipv4-dns-search=' "$k" \
        || { t_fail $n "network line lacks DNS options"; return; }
    [ "$(grep -c '^%post.*--erroronfail' "$k")" = 2 ] || { t_fail $n "%post without --erroronfail"; return; }
    ! grep -q '@@' "$k" && t_ok $n || t_fail $n "unreplaced @@"
}

ks_secret_roundtrip() {
    local n=ks_secret_roundtrip k="$COPY/.stage/cidata/ks.cfg"
    write_lab; set_lab CLIENT_DISTRO fedora; set_lab LUKS_PASSPHRASE "'a\"b\\c\$d #e'"
    build_in_copy client iso || { tail -n 5 "$COPY/.err.log" >&2; t_fail $n "client iso failed"; return; }
    python3 - "$k" <<'PY' && t_ok $n || t_fail $n "passphrase did not survive shlex"
import shlex, sys
line = next(l for l in open(sys.argv[1]) if l.startswith("part pv.01"))
sys.exit(0 if "--passphrase=a\"b\\c$d #e" in shlex.split(line, comments=True) else 1)
PY
}

ks_newline_rejected() {
    local n=ks_newline_rejected
    write_lab; set_lab CLIENT_DISTRO fedora; set_lab LUKS_PASSPHRASE "\$'a\nb'"
    if build_in_copy client iso; then t_fail $n "exit 0"; return; fi
    grep -q 'line break' "$COPY/.err.log" && t_ok $n || t_fail $n "no message: $(tail -n 2 "$COPY/.err.log")"
}

fedora_grub_patched() {
    local n=fedora_grub_patched f
    fedora_render || { t_fail $n "client iso failed"; return; }
    local iso="$COPY/.stage/fedora-ks.iso"
    for f in /EFI/BOOT/grub.cfg /boot/grub2/grub.cfg; do
        iso_cat "$iso" "$f" | grep -q 'inst.ks=hd:LABEL=CIDATA:/ks.cfg inst.text console=ttyS0,115200n8' \
            || { t_fail $n "$f not patched"; return; }
        iso_cat "$iso" "$f" | grep -qx 'set timeout=1' || { t_fail $n "$f timeout"; return; }
        iso_cat "$iso" "$f" | grep -qx 'set default="0"' || { t_fail $n "$f default"; return; }
        ! iso_cat "$iso" "$f" | grep -q 'rd.live.check' || { t_fail $n "$f has rd.live.check"; return; }
        [ "$(iso_cat "$iso" "$f" | grep -c 'inst.ks=')" = 2 ] || { t_fail $n "$f: not both entries patched"; return; }
    done
    t_ok $n
}

hw_ks_fedora() {
    local n=hw_ks_fedora iso="$COPY/.stage/mld-hw.iso" k f t
    write_lab; set_lab CLIENT_DISTRO fedora; set_lab CLIENT_DE gnome
    mkdir -p "$COPY/.stage/odj"; printf 'BLOB' > "$COPY/.stage/odj/HWTEST.txt"
    build_in_copy client hw-iso || { tail -n 5 "$COPY/.err.log" >&2; t_fail $n "client hw-iso failed"; return; }
    k=$(iso_cat "$iso" /ks.cfg)
    [ -n "$k" ] || { t_fail $n "no /ks.cfg in mld-hw.iso"; return; }
    local show='--passphrase|--password|^part |^user |^rootpw|qemu-guest-agent'
    local deny='--passphrase|--password|^part |^user |^rootpw|^text|^zerombr|^clearpart|^volgroup|^logvol'
    deny+='|^network |qemu-guest-agent|ttyS0'
    ! grep -qE -- "$deny" <<<"$k" \
        || { t_fail $n "ks.cfg: $(grep -E -- "$show" <<<"$k" | head -n 3)"; return; }
    grep -qx 'selinux --enforcing' <<<"$k" || { t_fail $n "no selinux line"; return; }
    grep -q '^services --enabled=sshd$' <<<"$k" || { t_fail $n "services line"; return; }
    grep -q '/run/install/repo/mld' <<<"$k" && grep -q '/run/install/repo/odj/' <<<"$k" \
        || { t_fail $n "no medium source"; return; }
    ! grep -qiE 'luks-pass|CIDATA' <<<"$k" || { t_fail $n "lab source left in ks.cfg"; return; }
    iso_ls "$iso" | grep -qx "'/mld/config.env'" && iso_ls "$iso" | grep -qx "'/odj/HWTEST.txt'" \
        || { t_fail $n "no /mld or /odj"; return; }
    iso_cat "$iso" /mld/config.env | grep -qx 'CLIENT_TARGET=hw' \
        || { t_fail $n "config.env has no CLIENT_TARGET=hw"; return; }
    iso_cat "$iso" /mld/config.env | grep -qx 'CLIENT_DISTRO=fedora' \
        || { t_fail $n "config.env has no CLIENT_DISTRO"; return; }
    t=$(mktemp -d "$TMPDIR/hwefi.XXXX")
    xorriso -indev "$iso" -report_el_torito plain 2>/dev/null | grep -q ' UEFI ' \
        || { t_fail $n "no UEFI El Torito entry"; return; }
    xorriso -indev "$iso" -report_el_torito plain 2>/dev/null | grep -q ' BIOS ' \
        || { t_fail $n "no BIOS El Torito entry"; return; }
    xorriso -osirrox on -indev "$iso" -extract /images/efiboot.img "$t/efiboot.img" >/dev/null 2>&1
    mtype -i "$t/efiboot.img" ::/EFI/BOOT/grub.cfg > "$t/efi.cfg" 2>/dev/null
    local ln s e
    ln=$(xorriso -indev "$iso" -report_el_torito as_mkisofs 2>/dev/null | grep '^-append_partition 2 ')
    [[ "$ln" =~ --interval:local_fs:([0-9]+)d-([0-9]+)d:: ]] || { t_fail $n "no appended partition 2: $ln"; return; }
    s=${BASH_REMATCH[1]}; e=${BASH_REMATCH[2]}
    dd if="$iso" of="$t/part2.img" bs=512 skip="$s" count=$((e - s + 1)) status=none
    mtype -i "$t/part2.img" ::/EFI/BOOT/grub.cfg > "$t/part2.cfg" 2>/dev/null
    iso_cat "$iso" /EFI/BOOT/grub.cfg > "$t/iso.cfg"
    iso_cat "$iso" /boot/grub2/grub.cfg > "$t/bios.cfg"
    for f in efi part2 iso bios; do
        [ "$(grep -c 'inst.ks=hd:LABEL=Fedora-E-dvd-x86_64-45:/ks.cfg' "$t/$f.cfg")" = 2 ] \
            || { t_fail $n "$f grub.cfg: not both entries patched"; return; }
        ! grep -qE 'inst.text|rd.live.check|ttyS0' "$t/$f.cfg" \
            || { t_fail $n "$f grub.cfg has inst.text, rd.live.check or ttyS0"; return; }
        grep -qx 'set default="0"' "$t/$f.cfg" || { t_fail $n "$f grub.cfg default"; return; }
    done
    t_ok $n
}

ks_validate() {
    local n=ks_validate
    command -v ksvalidator >/dev/null || { t_skip $n "ksvalidator not installed"; return; }
    fedora_render || { t_fail $n "client iso failed"; return; }
    ksvalidator -v F45 "$COPY/.stage/cidata/ks.cfg" >&2 && t_ok $n || t_fail $n "ksvalidator"
}

kernel_install_hook() {
    local n=kernel_install_hook h="$COPY/client/mld/boot/60-mld-uki.install" d log rc hk
    [ -f "$h" ] || { t_fail $n "no $h"; return; }
    d=$(mktemp -d "$TMPDIR/hook.XXXX"); log="$d/log"
    printf '#!/bin/sh\necho "$*" >> "%s"\n' "$log" > "$d/mld-uki"; chmod +x "$d/mld-uki"
    hk="$d/hook"; sed "s|/usr/local/sbin/mld-uki|$d/mld-uki|g" "$h" > "$hk"
    bash "$hk" add 6.17.1 /x /y || { t_fail $n "add failed"; return; }
    bash "$hk" remove 6.17.1 || { t_fail $n "remove failed"; return; }
    bash "$hk" inspect 6.17.1; rc=$?
    [ "$rc" = 0 ] || { t_fail $n "inspect exit $rc"; return; }
    [ "$(cat "$log")" = $'6.17.1\nremove 6.17.1' ] && t_ok $n || t_fail $n "log: $(cat "$log")"
    local row='^boot/60-mld-uki.install[[:space:]]*/etc/kernel/install.d/60-mld-uki.install[[:space:]]*755'
    grep -q "$row[[:space:]]*fedora\$" "$COPY/client/mld/install.list" \
        || t_fail $n "install.list row missing"
}

fedora_paths_used() {
    local n=fedora_paths_used hits
    hits=$(cd "$COPY" && grep -rn 'EFI/ubuntu\|initrd.img-' client/mld client/guest \
        | grep -v '^client/mld/distro.sh:' || true)
    [ -z "$hits" ] && t_ok $n || t_fail $n "hard-coded Ubuntu paths: $hits"
}

admin_pw_fedora() {
    local n=admin_pw_fedora d st src
    d=$(mktemp -d "$TMPDIR/apw.XXXX")
    src=$(sed -n '/^phase_admin_pw()/,/^}/p' "$COPY/client/mld/boot/phase.sh")
    [ -n "$src" ] || { t_fail $n "phase_admin_pw not found"; return; }
    printf '#!/bin/sh\necho "labadmin $PW_STATUS 2026-01-01 0 99999 7 -1"\n' > "$d/passwd"; chmod +x "$d/passwd"
    local prog="fail() { echo \"\$*\" >&2; exit 1; }; CLIENT_DISTRO=fedora; $src; phase_admin_pw"
    for st in P PS; do
        PW_STATUS=$st PATH="$d:$PATH" bash -c "$prog" 2>/dev/null \
            || { t_fail $n "status $st rejected"; return; }
    done
    PW_STATUS=NP PATH="$d:$PATH" bash -c "$prog" 2>/dev/null \
        && { t_fail $n "status NP accepted"; return; }
    t_ok $n
}

verify_facts_env() {
    local n=verify_facts_env d out
    d=$(mktemp -d "$TMPDIR/vf.XXXX"); mkdir -p "$d/etc"
    printf 'PROBE_USER=fromconfig\nCLIENT_DISTRO=ubuntu\n' > "$d/etc/config.env"
    cp "$COPY/client/mld/distro.sh" "$d/etc/distro.sh"
    sed -n '/^# config.env must not/,/^\. \/etc\/mld\/distro.sh/p' "$COPY/client/guest/verify-facts.sh" \
        | sed "s|/etc/mld/|$d/etc/|g" > "$d/head.sh"
    out=$(PROBE_USER=passedin bash -c '. "$1"; echo "$PROBE_USER $CLIENT_DISTRO"' _ "$d/head.sh" 2>&1)
    [ "$out" = "passedin ubuntu" ] && t_ok $n || t_fail $n "got: $out"
    out=$(bash -c '. "$1"; echo "$PROBE_USER"' _ "$d/head.sh" 2>&1)
    [ "$out" = fromconfig ] || t_fail $n "unset value not taken from config.env: $out"
}

authselect_profile_edit() {
    local n=authselect_profile_edit d f src out
    d=$(mktemp -d "$TMPDIR/asel.XXXX"); mkdir -p "$d/bin"
    src=$(sed -n '/^pam_enable_mount()/,/^}/p' "$COPY/client/mld/home/phase.sh")
    [ -n "$src" ] || { t_fail $n "pam_enable_mount not found"; return; }
    cat > "$d/bin/authselect" <<STUB
#!/bin/sh
echo "\$*" >> "$d/authselect.log"
if [ "\$1" = create-profile ]; then
    mkdir -p "$d/as/custom/mld"
    cp "$COPY/tests/fixtures/authselect-system-auth" "$d/as/custom/mld/system-auth"
    cp "$COPY/tests/fixtures/authselect-password-auth" "$d/as/custom/mld/password-auth"
fi
STUB
    chmod +x "$d/bin/authselect"
    run() {
        PATH="$d/bin:$PATH" AUTHSELECT_DIR="$d/as" \
            bash -c "fail() { echo \"\$*\" >&2; exit 1; }; CLIENT_DISTRO=fedora; $src; pam_enable_mount" 2>&1
    }
    out=$(run) || { t_fail $n "first run: $out"; return; }
    grep -q '^create-profile mld -b sssd$' "$d/authselect.log" || { t_fail $n "profile not created"; return; }
    for f in system-auth password-auth; do
        [ "$(grep -c 'pam_mount.so' "$d/as/custom/mld/$f")" = 2 ] || { t_fail $n "$f: want 2 pam_mount lines"; return; }
        awk '{ l[NR] = $0 }
             END { for (i = 2; i <= NR; i++) {
                 if (l[i-1] ~ /^auth +optional +pam_mount.so/) m++
                 if (i < NR && l[i] ~ /^auth +\[default=1 ignore=ignore success=ok\] +pam_usertype.so isregular *$/ &&
                     l[i-1] ~ /^auth +optional +pam_mount.so/ && l[i+1] ~ /^auth +sufficient +pam_sss.so/) a++
                 if (l[i] ~ /^-session +optional +pam_systemd.so/ && l[i-1] ~ /^session +optional +pam_mount.so/) s++ }
                 exit (a == 1 && m == 1 && s == 1) ? 0 : 1 }' "$d/as/custom/mld/$f" \
            || { t_fail $n "$f: pam_mount not before pam_usertype guard / pam_systemd"; return; }
    done
    grep -q '^select custom/mld --force$' "$d/authselect.log" || { t_fail $n "profile not selected"; return; }
    cp -r "$d/as" "$d/as.1"
    out=$(run) || { t_fail $n "second run: $out"; return; }
    diff -r "$d/as.1" "$d/as" >/dev/null && t_ok $n || t_fail $n "second run changed the profile"
    rm -rf "$d"
}

selinux_lists_parse() {
    local n=selinux_lists_parse d="$COPY/client/mld/selinux" f
    for f in phase.sh mld.te fcontexts.list booleans.list avc-ignore.list avc-report.sh; do
        [ -f "$d/$f" ] || { t_fail $n "no selinux/$f"; return; }
    done
    awk '!/^[[:space:]]*(#|$)/ && (NF != 2 || $1 !~ /^\//) { bad = 1 } END { exit bad }' "$d/fcontexts.list" \
        || { t_fail $n "fcontexts.list: want '<regex starting with /> <type>'"; return; }
    awk '!/^[[:space:]]*(#|$)/ && (NF != 2 || $2 !~ /^(on|off)$/) { bad = 1 } END { exit bad }' "$d/booleans.list" \
        || { t_fail $n "booleans.list: want '<name> on|off'"; return; }
    awk '!/^[[:space:]]*(#|$)/ && $2 !~ /^https?:\/\// { bad = 1 } END { exit bad }' "$d/avc-ignore.list" \
        || { t_fail $n "avc-ignore.list: 2nd field must be a URL"; return; }
    grep -q '^selinux/avc-report.sh[[:space:]]*/usr/local/libexec/mld-avc-report[[:space:]]*755[[:space:]]*fedora$' \
        "$COPY/client/mld/install.list" \
        || { t_fail $n "install.list row for avc-report.sh missing"; return; }
    for f in phase.sh mld.te fcontexts.list booleans.list avc-ignore.list; do
        grep -q "^selinux/$f[[:space:]]*-[[:space:]]*644[[:space:]]*fedora$" "$COPY/client/mld/install.list" \
            || { t_fail $n "install.list row for $f missing"; return; }
    done
    t_ok $n
}

selinux_te_compiles() {
    local n=selinux_te_compiles d
    command -v checkmodule >/dev/null || { t_skip $n "checkmodule not installed"; return; }
    d=$(mktemp -d "$TMPDIR/te.XXXX")
    checkmodule -M -m -o "$d/mld.mod" "$COPY/client/mld/selinux/mld.te" >&2 && t_ok $n || t_fail $n "checkmodule"
    rm -rf "$d"
}

selinux_avc_report() {
    local n=selinux_avc_report d out
    d=$(mktemp -d "$TMPDIR/avc.XXXX"); mkdir -p "$d/bin"
    printf '%s\n' '# comment' 'denied.*ignored_t https://example.org/bug/1' > "$d/ignore"
    cat > "$d/bin/ausearch" <<'STUB'
#!/bin/sh
case " $* " in *" --input-logs "*) ;; *) echo "stub: no --input-logs, real ausearch reads stdin" >&2; exit 3 ;; esac
case "$STUB_MODE" in
    none) echo "<no matches>" >&2; exit 1 ;;
    broken) echo "Error opening audit log" >&2; exit 1 ;;
    *) echo "type=AVC msg=audit(1.1:1): avc:  denied  { write } for comm=x scontext=a:b:ignored_t:s0"
       echo "type=AVC msg=audit(1.1:2): avc:  denied  { read } for comm=y scontext=a:b:kept_t:s0" ;;
esac
STUB
    chmod +x "$d/bin/ausearch"
    local rep="$COPY/client/mld/selinux/avc-report.sh"
    out=$(STUB_MODE=none PATH="$d/bin:$PATH" AVC_IGNORE="$d/ignore" bash "$rep"); local rc=$?
    { [ "$rc" = 0 ] && [ -z "$out" ]; } || { t_fail $n "no events: exit $rc, output '$out'"; return; }
    if STUB_MODE=broken PATH="$d/bin:$PATH" AVC_IGNORE="$d/ignore" bash "$rep" >/dev/null 2>&1; then
        t_fail $n "ausearch failure reported as no denials"; return; fi
    out=$(STUB_MODE=some PATH="$d/bin:$PATH" AVC_IGNORE="$d/ignore" bash "$rep")
    [ "$(printf '%s\n' "$out" | wc -l)" = 1 ] && [[ "$out" == *kept_t* ]] && t_ok $n || t_fail $n "filter: $out"
    rm -rf "$d"
}

selinux_phase_logic() {
    local n=selinux_phase_logic d src out
    d=$(mktemp -d "$TMPDIR/sel.XXXX"); mkdir -p "$d/bin" "$d/cfg/selinux" "$d/state"
    src=$(cat "$COPY/client/mld/selinux/phase.sh")
    cp "$COPY/client/mld/selinux/"{booleans.list,fcontexts.list,mld.te} "$d/cfg/selinux/"
    local c
    for c in setsebool semanage semodule_package semodule restorecon; do
        printf '#!/bin/sh\necho "%s $*" >> "%s/calls.log"\n' "$c" "$d" > "$d/bin/$c"
    done
    printf '#!/bin/sh\necho "$GETENFORCE"\n' > "$d/bin/getenforce"
    printf '#!/bin/sh\necho "checkmodule $*" >> "%s/calls.log"\n%s\n' "$d" \
        'while [ $# -gt 0 ]; do [ "$1" = -o ] && : > "$2"; shift; done' > "$d/bin/checkmodule"
    printf '#!/bin/sh\n%s echo "semanage $*" >> "%s/calls.log"\n' \
        'case " $* " in *" -l "*) [ -z "$FCTX_PRESENT" ] || echo "$FCTX_PRESENT" ;; esac;' "$d" > "$d/bin/semanage"
    chmod +x "$d"/bin/*
    run() {
        PATH="$d/bin:$PATH" CFG="$d/cfg" STATE="$d/state" \
            bash -c "fail() { echo \"\$*\" >&2; exit 1; }; phase() { :; }; $src; $1" 2>&1
    }
    out=$(GETENFORCE=Permissive run phase_selinux) && { t_fail $n "permissive accepted"; return; }
    [[ "$out" == *"SELinux is not enforcing"* ]] || { t_fail $n "no message: $out"; return; }
    out=$(GETENFORCE=Enforcing run phase_selinux) || { t_fail $n "enforcing run: $out"; return; }
    grep -q '^setsebool -P use_samba_home_dirs on$' "$d/calls.log" || { t_fail $n "no setsebool"; return; }
    grep -q '^semanage fcontext -a -t certmonger_unconfined_exec_t /usr/local/libexec/mld-cm-submit$' "$d/calls.log" \
        || { t_fail $n "no semanage -a"; return; }
    grep -q '^restorecon -R /usr' "$d/calls.log" || { t_fail $n "no restorecon"; return; }
    grep -q '^semodule -i' "$d/calls.log" || { t_fail $n "module not installed"; return; }
    [ -s "$d/state/selinux.sha" ] || { t_fail $n "no selinux.sha"; return; }
    : > "$d/calls.log"
    out=$(GETENFORCE=Enforcing FCTX_PRESENT='/usr/local/libexec/mld-cm-submit all files x' run phase_selinux) \
        || { t_fail $n "second run: $out"; return; }
    grep -q '^semanage fcontext -m -t certmonger_unconfined_exec_t' "$d/calls.log" \
        || { t_fail $n "no semanage -m when present"; return; }
    ! grep -q '^semodule -i\|^checkmodule' "$d/calls.log" || { t_fail $n "module rebuilt without change"; return; }
    : > "$d/calls.log"
    out=$(GETENFORCE=Permissive run phase_selinux_restore) || { t_fail $n "restore: $out"; return; }
    grep -q '^restorecon' "$d/calls.log" && ! grep -q '^setsebool\|^semodule' "$d/calls.log" && t_ok $n \
        || t_fail $n "restore-only run: $(cat "$d/calls.log")"
    rm -rf "$d"
}

fedora_repo_keys() {
    local n=fedora_repo_keys g r rg asc want got rf
    g=$(mktemp -d "$TMPDIR/gnupg.XXXX"); chmod 700 "$g"
    for r in apps/google-chrome:google-linux-signing:0 vpn/snx-rs:snx-rs:1; do
        rg=${r##*:}; r=${r%:*}
        asc="$COPY/client/mld/${r%%/*}/${r#*:}.asc"
        rf="$COPY/client/mld/${r%%:*}.repo"
        [ -f "$asc" ] && [ -f "$rf" ] || { t_fail $n "missing file for $r"; rm -rf "$g"; return; }
        want=$(grep -o 'fingerprint [0-9A-F]\{40\}' "$rf" | head -1 | cut -d' ' -f2)
        got=$(GNUPGHOME=$g gpg --show-keys --with-colons "$asc" 2>/dev/null | awk -F: '/^fpr/ {print $10; exit}')
        [ -n "$want" ] && [ "$want" = "$got" ] || { t_fail $n "$r: comment '$want' key '$got'"; rm -rf "$g"; return; }
        grep -q '^gpgcheck=1' "$rf" && grep -q "^repo_gpgcheck=$rg\$" "$rf" \
            && grep -q '^gpgkey=file:///etc/pki/rpm-gpg/mld-' "$rf" \
            || { t_fail $n "$r: repo options"; rm -rf "$g"; return; }
    done
    [ "$want" = 81EE7E8627CB26ECA46CE6572BE0562851E26770 ] && t_ok $n || t_fail $n "snx-rs fingerprint $want"
    rm -rf "$g"
}

# vrun FIXTURE DISTRO DE CIFS_HOME [KEY=VALUE...]: runs client_verify on a fact fixture, prints the check lines.
# KEY=VALUE overrides a fact; KEY= removes it.
vrun() {
    local fx=$1 distro=$2 de=$3 cifs=$4 w dm kv; shift 4
    w=$(mktemp -d "$TMPDIR/vrun.XXXX"); cp "$COPY/tests/fixtures/$fx" "$w/facts"
    for kv in "$@"; do sed -i "/^${kv%%=*}=/d" "$w/facts"; [ -z "${kv#*=}" ] || printf '%s\n' "$kv" >> "$w/facts"; done
    local stub='#!/bin/sh\ncase "$2" in *autoenroll*) '
    stub+='printf "mld-MLD-LinuxComputer\\nstatus: MONITORING\\ntoken=%%s\\n" "%s" ;; esac\nexit 0\n'
    # shellcheck disable=SC2059
    printf "$stub" "'mld-machine'" > "$w/guest-exec.sh"
    chmod +x "$w/guest-exec.sh"
    dm=gdm.service; [ "$de" = kde ] && { dm=sddm.service; [ "$distro" = fedora ] && dm=plasmalogin.service; }
    ( cd "$w" && export STAGE="$w" DOMAIN=lab.test LINUX_GROUP=Linux-Users PROBE_USER=u DC_IP=10.0.0.2 \
        PKI_ENROLL=machine MACHINE_TOKEN_PIN=1 ENROLL_TPM2=1 UKI=1 UKI_TRUST=db SNX_RS=1 \
        CLIENT_DISTRO="$distro" CLIENT_DE=$de CLIENT_DM_UNIT=$dm CIFS_HOME=$cifs
      unset FIDO2_HOSTDEV
      warn() { :; }; log() { :; }; die() { echo "die: $*" >&2; exit 1; }
      . "$COPY/lib/tests.sh"
      guest_run() { cat "$w/facts"; }; client_boot_facts() { :; }
      client_verify_login() { :; }; client_verify_browsers() { :; }
      client_verify; echo "rc=$?" ) 2>&1
    rm -rf "$w"
}

# verify_checks_fedora_gnome: prints the problems of the Fedora GNOME fixture and the SELinux, AVC, authselect facts.
verify_checks_fedora_gnome() {
    local out bad="" f=verify-facts-fedora.txt
    out=$(vrun $f fedora gnome 1)
    grep -q 'FAIL' <<<"$out" && bad+="gnome fixture: $(grep FAIL <<<"$out" | head -3 | tr '\n' '|'); "
    grep -q '^  ok    SELinux enforcing' <<<"$out" || bad+="no SELinux check; "
    grep -q 'no unexpected AVC' <<<"$out" || bad+="no AVC check; "
    grep -q 'authselect custom/mld' <<<"$out" || bad+="no authselect check; "
    grep -qE '^  (ok|FAIL)    ?desktop user unit' <<<"$out" && bad+="enabled-unit check on Fedora GNOME; "
    grep -q 'SDDM' <<<"$out" && bad+="SDDM check on Fedora; "
    grep -q 'Firefox from' <<<"$out" || bad+="no Firefox check; "
    grep -q 'WARN' <<<"$out" && bad+="WARN on GNOME; "
    out=$(vrun $f fedora gnome 1 selinux=Permissive)
    grep -q '^  FAIL  SELinux enforcing' <<<"$out" || bad+="Permissive: no FAIL; "
    out=$(vrun $f fedora gnome 1 avc_unexpected=2)
    grep -q '^  FAIL  no unexpected AVC' <<<"$out" || bad+="avc 2: no FAIL; "
    out=$(vrun $f fedora gnome 1 avc_unexpected=error)
    grep -q '^  FAIL  no unexpected AVC' <<<"$out" || bad+="avc error: no FAIL; "
    out=$(vrun $f fedora gnome 1 authselect=sssd)
    grep -q '^  FAIL  authselect' <<<"$out" || bad+="authselect sssd with CIFS_HOME=1: no FAIL; "
    out=$(vrun $f fedora gnome 0 'authselect=sssd with-mkhomedir')
    grep -q 'FAIL' <<<"$out" && bad+="CIFS_HOME=0 sssd+mkhomedir: FAIL; "
    grep -q 'authselect sssd with-mkhomedir' <<<"$out" || bad+="no CIFS_HOME=0 authselect check; "
    printf '%s' "$bad"
}

# verify_checks_fedora_more: prints the problems of the Fedora GNOME facts for Firefox, desktop, updates, snx-rs.
verify_checks_fedora_more() {
    local out bad="" f=verify-facts-fedora.txt
    out=$(vrun $f fedora gnome 1 firefox_vendor=Mozilla)
    grep -q '^  FAIL  Firefox' <<<"$out" || bad+="firefox vendor Mozilla: no FAIL; "
    grep -q 'desktop icons: not used (stock Fedora GNOME, launchers in the app grid)' "$COPY/lib/tests.sh" \
        && grep -q 'CLIENT_DE" = gnome \]; then desk=; fi' "$COPY/lib/tests.sh" \
        || bad+="login: Fedora GNOME still runs the desktop unit; "
    out=$(vrun $f fedora gnome 1 desktop_unit=enabled)
    grep -q '^  FAIL  no desktop user unit' <<<"$out" || bad+="gnome unit enabled: no FAIL; "
    out=$(vrun $f fedora gnome 1 'upd_repos=fedora updates ')
    grep -q '^  FAIL  update sources' <<<"$out" || bad+="repos missing: no FAIL; "
    out=$(vrun $f fedora gnome 1 authselect=custom/mld-evil)
    grep -q '^  FAIL  authselect' <<<"$out" || bad+="authselect prefix match: no FAIL; "
    out=$(vrun $f fedora gnome 1 'authselect=custom/mld with-mkhomedir')
    grep -q '^  ok    authselect custom/mld' <<<"$out" || bad+="authselect custom/mld with feature: not ok; "
    out=$(vrun $f fedora gnome 1 plymouth_theme=bgrt)
    grep -q '^  FAIL  Plymouth theme mld' <<<"$out" || bad+="plymouth bgrt: no FAIL; "
    out=$(vrun $f fedora gnome 1 \
        "dock_default=['firefox.desktop', 'mld-o365-outlook.desktop', 'google-chrome.desktop']")
    grep -q '^  FAIL  dock pins' <<<"$out" || bad+="dock with the Ubuntu Firefox name: no FAIL; "
    out=$(vrun $f fedora gnome 1 upd_conf=no)
    grep -q '^  FAIL  automatic updates' <<<"$out" || bad+="apply_updates no: no FAIL; "
    out=$(vrun $f fedora gnome 1 upd_conf_deprecated=present)
    grep -q '^  FAIL  automatic updates' <<<"$out" || bad+="deprecated automatic.conf present: no FAIL; "
    out=$(vrun $f fedora gnome 1 snx_pkg=)
    grep -q '^  FAIL  snx-rs installed' <<<"$out" || bad+="snx-rs missing: no FAIL; "
    printf '%s' "$bad"
}

# verify_checks_fedora_kde: prints the problems of the Fedora KDE facts.
verify_checks_fedora_kde() {
    local out bad="" f=verify-facts-fedora.txt
    local kde=('de_installed=kde' 'dm_unit=plasmalogin.service/active' 'desktop_unit=enabled' 'kde_pins=1'
        'plasma_shadow=absent')
    local warn='WARN  AD user login on the Fedora KDE greeter: manual check'
    warn+=' (no user-list setting found in plasma-login-manager; see spec Probe results item 2)'
    out=$(vrun $f fedora kde 1 "${kde[@]}" greeter_unit=active greeter_dropin=present)
    grep -q 'FAIL' <<<"$out" && bad+="kde fixture: $(grep FAIL <<<"$out" | head -3 | tr '\n' '|'); "
    grep -q '^  ok    desktop user unit' <<<"$out" || bad+="kde: no desktop user unit check; "
    grep -q 'plasma-login-manager' <<<"$out" || bad+="kde: no greeter check; "
    grep -qF "$warn" <<<"$out" || bad+="kde: no WARN line; "
    grep -q 'SDDM' <<<"$out" && bad+="kde: SDDM check on Fedora; "
    out=$(vrun $f fedora kde 1 "${kde[@]}" greeter_unit=inactive greeter_dropin=absent)
    grep -q '^  FAIL  plasma-login-manager' <<<"$out" || bad+="kde greeter inactive: no FAIL; "
    printf '%s' "$bad"
}

verify_checks_fedora() {
    local n=verify_checks_fedora bad=""
    bad+=$(verify_checks_fedora_gnome)
    bad+=$(verify_checks_fedora_more)
    bad+=$(verify_checks_fedora_kde)
    [ -z "$bad" ] && t_ok $n || t_fail $n "$bad"
}

verify_checks_ubuntu() {
    local n=verify_checks_ubuntu out bad="" f=verify-facts-ubuntu.txt
    out=$(vrun $f ubuntu gnome 1)
    grep -q 'FAIL' <<<"$out" && bad+="gnome fixture: $(grep FAIL <<<"$out" | head -3 | tr '\n' '|'); "
    grep -q 'SELinux\|AVC\|authselect' <<<"$out" && bad+="Fedora check on Ubuntu; "
    grep -q '^  ok    Firefox from Mozilla' <<<"$out" || bad+="no Firefox from Mozilla; "
    grep -q '^  ok    desktop user unit' <<<"$out" || bad+="no desktop user unit; "
    grep -q '^  ok    update sources' <<<"$out" || bad+="no update sources; "
    out=$(vrun $f ubuntu gnome 1 firefox_origin=http://archive.ubuntu.com)
    grep -q '^  FAIL  Firefox from Mozilla' <<<"$out" || bad+="firefox origin: no FAIL; "
    out=$(vrun $f ubuntu gnome 1 \
        "dock_default=['org.mozilla.firefox.desktop', 'mld-o365-outlook.desktop', 'google-chrome.desktop']")
    grep -q '^  FAIL  dock pins' <<<"$out" || bad+="dock without firefox.desktop: no FAIL; "
    out=$(vrun $f ubuntu gnome 1 uu_pkg=)
    grep -q '^  FAIL  automatic updates' <<<"$out" || bad+="uu missing: no FAIL; "
    out=$(vrun $f ubuntu kde 1 de_installed=kde dm_unit=sddm.service/active kde_pins=1 plasma_shadow=absent \
        sddm_userlist=999 sddm_theme=breeze sddm_bg=/usr/share/mld/brand/background.png)
    grep -q 'FAIL' <<<"$out" && bad+="kde fixture: $(grep FAIL <<<"$out" | head -3 | tr '\n' '|'); "
    grep -q 'SDDM theme' <<<"$out" || bad+="kde: no SDDM check; "
    grep -q 'WARN' <<<"$out" && bad+="WARN on Ubuntu; "
    [ -z "$bad" ] && t_ok $n || t_fail $n "$bad"
}

cert_ca_trust() {
    local n=cert_ca_trust d bad="" distro dir pre want_cmd out c rc
    d=$(mktemp -d "$TMPDIR/cact.XXXX")
    openssl req -x509 -newkey rsa:2048 -nodes -keyout "$d/k" -subj /CN=test-ca -days 2 -out "$d/ca.pem" 2>/dev/null
    openssl x509 -in "$d/ca.pem" -outform DER | base64 -w0 > "$d/der.b64"
    mkdir -p "$d/bin"
    printf '#!/bin/sh\nprintf "dn: x\\ncACertificate:: %%s\\n" "$(cat %s)"\n' "$d/der.b64" > "$d/bin/ldapsearch"
    printf '#!/bin/sh\nexit 0\n' > "$d/bin/kinit"
    printf '#!/bin/sh\necho 0\n' > "$d/bin/id"
    for c in update-ca-certificates update-ca-trust; do
        printf '#!/bin/sh\necho "%s $*" >> %s/trust.log\n' "$c" "$d" > "$d/bin/$c"
    done
    chmod +x "$d/bin/"*
    for distro in ubuntu fedora; do
        rm -rf "$d/etc" "$d/usr" "$d/trust.log"
        mkdir -p "$d/etc/mld" "$d/etc/pki/ca-trust/source/anchors" "$d/usr/local/share/ca-certificates/mld"
        sed "s|/etc/|$d/etc/|g; s|/usr/local/|$d/usr/local/|g" "$COPY/client/mld/distro.sh" > "$d/etc/mld/distro.sh"
        sed "s|/etc/|$d/etc/|g; s|/usr/local/|$d/usr/local/|g; s|/run/mld|$d/run-mld|g" \
            "$COPY/client/mld/cert/cert.sh" > "$d/cert.sh"
        printf "CLIENT_DISTRO=%s\n" "$distro" > "$d/etc/mld/config.env"
        printf "DC_FQDN='dc'\nREALM='LAB.TEST'\nCA_NAME='ca'\nDOMAIN_DN='DC=lab,DC=test'\nPKI_ENROLL='machine'\n%s\n" \
            "CLIENT_DISTRO='$distro'" > "$d/etc/mld-cert.conf"
        if [ "$distro" = fedora ]; then
            printf "CA_ANCHOR_DIR='%s/etc/pki/ca-trust/source/anchors'\nCA_ANCHOR_PREFIX='mld-'\n" "$d" \
                >> "$d/etc/mld-cert.conf"
            dir=$d/etc/pki/ca-trust/source/anchors pre=mld- want_cmd="update-ca-trust extract"
        else
            printf "CA_ANCHOR_DIR='%s/usr/local/share/ca-certificates/mld'\nCA_ANCHOR_PREFIX=''\n" "$d" \
                >> "$d/etc/mld-cert.conf"
            dir=$d/usr/local/share/ca-certificates/mld pre= want_cmd="update-ca-certificates "
        fi
        cp "$d/ca.pem" "$dir/other.crt"; cp "$d/ca.pem" "$dir/${pre}stale.crt"
        out=$( unset CLIENT_DISTRO; PATH="$d/bin:$PATH" bash "$d/cert.sh" ca 2>&1 ); rc=$?
        [ $rc = 0 ] || bad+="$distro: exit $rc: $out; "
        [ "$(cat "$d/trust.log" 2>/dev/null)" = "$want_cmd" ] \
            || bad+="$distro: trust command '$(cat "$d/trust.log" 2>/dev/null)'; "
        [ -e "$dir/${pre}stale.crt" ] && bad+="$distro: stale file kept; "
        [ "$distro" = fedora ] && [ ! -e "$dir/other.crt" ] && bad+="fedora: foreign file deleted; "
        [ "$distro" = ubuntu ] && [ -e "$dir/other.crt" ] && bad+="ubuntu: dedicated dir not cleaned; "
        [ "$(ls "$dir"/${pre}mld-*.crt "$dir"/mld-*.crt 2>/dev/null | sort -u | wc -l)" = 1 ] \
            || bad+="$distro: want one mld-<fp>.crt; "
        grep -q '"CACertificates": \["' "$d/etc/opt/chrome/policies/managed/mld-ca.json" 2>/dev/null \
            || bad+="$distro: no Chrome policy; "
    done
    # Fedora conf without CA_ANCHOR_DIR must stop with a clear message.
    printf "DC_FQDN='dc'\nREALM='L'\nCA_NAME='ca'\nDOMAIN_DN='DC=l'\nPKI_ENROLL='m'\nCLIENT_DISTRO='fedora'\n" \
        > "$d/etc/mld-cert.conf"
    out=$(PATH="$d/bin:$PATH" bash "$d/cert.sh" ca 2>&1) && bad+="fedora without CA_ANCHOR_DIR: no abort; "
    case "$out" in *"client resume"*) ;; *) bad+="fedora without CA_ANCHOR_DIR: no message; " ;; esac
    rm -rf "$d"
    [ -z "$bad" ] && t_ok $n || t_fail $n "$bad"
}

in_ubuntu_arm() {
    head -n "$2" "$1" | awk -v ln="$2" '
        /^[ \t]*#/ { if (NR == ln) r = u; next }
        /^[ \t]*esac([ \t;]|$)/ { u = 0 }
        /^[ \t]*[A-Za-z0-9_|*]+\)/ { l = $0; sub(/^[ \t]*/, "", l); u = (l ~ /^ubuntu\)/) }
        { if (NR == ln) r = u }
        /;;[ \t]*$/ { u = 0 }
        END { exit r ? 0 : 1 }'
}

no_dpkg_on_fedora_paths() {
    local n=no_dpkg_on_fedora_paths bad="" line f ln t
    t=$(mktemp "$TMPDIR/arm.XXXX")
    printf '%s\n' 'case "$D" in' 'ubuntu) apt-get x ;;' 'fedora) true ;;' 'esac' 'apt-get y' > "$t"
    in_ubuntu_arm "$t" 2 || { t_fail $n "self-test: one-line ubuntu arm not accepted"; rm -f "$t"; return; }
    in_ubuntu_arm "$t" 5 && { t_fail $n "self-test: unguarded line after esac accepted"; rm -f "$t"; return; }
    rm -f "$t"
    while IFS= read -r line; do
        f=${line%%:*}; ln=${line#*:}; ln=${ln%%:*}
        case "$line" in *:[0-9]*:#*|*:[0-9]*:[[:space:]]*#*) continue ;; esac
        [ "$f" = client/mld/distro.sh ] && continue
        in_ubuntu_arm "$COPY/$f" "$ln" || bad+="$line"$'\n'
    done < <(cd "$COPY" \
        && grep -rn 'dpkg\|apt-get\|apt-config\|pam-auth-update\|update-alternatives' client/mld client/guest)
    [ -z "$bad" ] && t_ok $n || t_fail $n "Ubuntu package commands outside an ubuntu) arm: $bad"
}

fedora_desktop_rules() {
    local n=fedora_desktop_rules r de out bad="" f
    r=$(mktemp -d "$TMPDIR/desk.XXXX")
    mkdir -p "$r/cfg/desktop"
    cp "$COPY"/client/mld/desktop/{pins.list,dconf-user.profile} "$r/cfg/desktop/"
    sed -e "s#/etc/dconf#$r/etc/dconf#g" -e "s#/etc/plasmalogin#$r/etc/plasmalogin#g" \
        -e "s#/usr/local/share/plasma#$r/usr/local/share/plasma#g" -e "s#/usr/share/plasma/#$r/usr/share/plasma/#g" \
        "$COPY/client/mld/desktop/phase.sh" > "$r/phase.sh"
    # The stock profile of dconf-51.0-1.fc45 (/etc/dconf/profile/user).
    mkdir -p "$r/etc/dconf/profile"
    printf '%s\n' user-db:user system-db:local system-db:site system-db:distro > "$r/stock.profile"
    for de in gnome kde; do
        cp "$r/stock.profile" "$r/etc/dconf/profile/user"
        out=$(CLIENT_DISTRO=fedora CLIENT_DE=$de CFG="$r/cfg" R="$r" bash -c '
            systemctl() { echo "systemctl $*" >> "$R/log.$CLIENT_DE"; }
            dconf() { echo "dconf $*" >> "$R/log.$CLIENT_DE"; }
            loginctl() { :; }
            pkg_install() { echo "pkg_install $*" >> "$R/log.$CLIENT_DE"; }
            pkg_installed() { return 1; }
            fail() { echo "fail $*" >&2; exit 1; }
            phase() { :; }
            . "$R/phase.sh"
            desktop_pins
            desktop_user_unit' 2>&1) || { t_fail $n "$de: $out"; return; }
        [ "$de" != gnome ] || cp "$r/etc/dconf/db/local.d/10-mld-desktop" "$r/gnome.dconf" 2>/dev/null
        cmp -s "$r/stock.profile" "$r/etc/dconf/profile/user" || bad+="$de: stock dconf profile changed or removed; "
    done
    printf '%s\n' user-db:user system-db:site > "$r/etc/dconf/profile/user"
    ( CLIENT_DISTRO=fedora CFG="$r/cfg" \
        bash -c '. "$1"; desktop_dconf_profile; desktop_dconf_profile' _ "$r/phase.sh" ) \
        || bad+="desktop_dconf_profile failed; "
    [ "$(grep -cx 'system-db:local' "$r/etc/dconf/profile/user")" = 1 ] \
        && grep -qx system-db:site "$r/etc/dconf/profile/user" \
        || bad+="profile without local: want one added line, other lines kept; "
    grep -q "'org.mozilla.firefox.desktop'" "$r/gnome.dconf" 2>/dev/null || bad+="gnome: no Fedora Firefox pin; "
    grep -q "'firefox.desktop'\|@firefox" "$r/gnome.dconf" 2>/dev/null \
        && bad+="gnome: Ubuntu Firefox name or @firefox in the pins; "
    grep -q 'favorite-apps=\[.*mld-o365-outlook.desktop' "$r/gnome.dconf" 2>/dev/null \
        || bad+="gnome: no favorite-apps with mld-o365-outlook.desktop; "
    grep -q 'enable mld-desktop' "$r/log.gnome" && bad+="gnome: mld-desktop enabled; "
    grep -q 'disable mld-desktop' "$r/log.gnome" || bad+="gnome: mld-desktop not disabled; "
    grep -q 'enable mld-desktop' "$r/log.kde" || bad+="kde: mld-desktop not enabled; "
    [ -s "$r/usr/share/plasma/shells/org.kde.plasma.desktop/contents/updates/mld-pins.js" ] \
        || bad+="kde: no pins script; "
    f=$r/etc/plasmalogin.conf.d/90-mld.conf
    grep -q '^Image=file:///usr/share/mld/brand/background.png$' "$f" 2>/dev/null \
        || bad+="kde: no background in 90-mld.conf; "
    grep -q 'restart plasmalogin.service' "$r/log.kde" || bad+="kde: no plasmalogin restart; "
    grep -q 'sddm\|apt-get\|dpkg' "$r/log.kde" "$f" 2>/dev/null && bad+="kde: sddm or dpkg used on fedora; "
    grep -q 'plymouth-set-default-theme mld' "$COPY/client/mld/brand/phase.sh" \
        || bad+="brand: no plymouth-set-default-theme mld; "
    rm -rf "$r"
    [ -z "$bad" ] && t_ok $n || t_fail $n "$bad"
}

autoenroll_module_path() {
    local n=autoenroll_module_path d src out
    d=$(mktemp -d "$TMPDIR/p11.XXXX")
    mkdir -p "$d/lib64/pkcs11" "$d/deb/pkcs11"; : > "$d/lib64/pkcs11/libtpm2_pkcs11.so"
    src=$(sed -n '/^def tpm2_pkcs11_lib(/,/^$/p' "$COPY/client/mld/cert/autoenroll.py")
    [ -n "$src" ] || { t_fail $n "tpm2_pkcs11_lib not found"; rm -rf "$d"; return; }
    out=$(python3 -I -c "import os, sys
$src
print(tpm2_pkcs11_lib(['$d/none/libtpm2_pkcs11.so', '$d/lib64/pkcs11/libtpm2_pkcs11.so',
                      '$d/deb/pkcs11/libtpm2_pkcs11.so']))
try:
    tpm2_pkcs11_lib(['$d/none/x'])
except SystemExit:
    print('exit')") || { t_fail $n "python failed"; rm -rf "$d"; return; }
    [ "$out" = "$d/lib64/pkcs11/libtpm2_pkcs11.so"$'\n'exit ] && t_ok $n || t_fail $n "got: $out"
    rm -rf "$d"
}

# reboot_rule_check LABEL WANT OUT LOG: prints the problems of one reboot.sh run.
reboot_rule_check() {
    local l=$1 want=$2 out=$3 log=$4 bad=""
    case "$want" in
    "") [ -z "$out" ] || bad+="$l: output '$out'; "
        ! grep -q 'systemctl reboot' "$log" || bad+="$l: reboot called; " ;;
    "reboot required by")
        case "$out" in "reboot required by"*"no user session, reboot now") ;; *) bad+="$l: output '$out'; " ;; esac
        grep -q 'systemctl reboot' "$log" || bad+="$l: no reboot; " ;;
    *)  [ "$out" = "$want" ] || bad+="$l: output '$out'; "
        ! grep -q 'systemctl reboot' "$log" || bad+="$l: reboot called; " ;;
    esac
    printf '%s' "$bad"
}

reboot_rule_fedora() {
    local n=reboot_rule_fedora r d out rc bad="" c exp_out fb au dc au_unit
    r=$(mktemp -d "$TMPDIR/reboot.XXXX")
    mkdir -p "$r/bin" "$r/etc"
    sed -e "s#/etc/mld/#$r/etc/#g" -e "s#/run/reboot-required#$r/reboot-required#g" \
        "$COPY/client/mld/update/reboot.sh" > "$r/reboot.sh"
    cp "$COPY/client/mld/distro.sh" "$r/etc/distro.sh"
    printf 'luks UUID=x none tpm2-device=auto\n' > "$r/crypttab"
    cat > "$r/bin/dnf" <<'STUB'
#!/bin/sh
[ "$*" = "needs-restarting -r" ] || { echo "unexpected dnf $*" >&2; exit 99; }
exit "$DNF_RC"
STUB
    cat > "$r/bin/systemctl" <<'STUB'
#!/bin/sh
echo "systemctl $*" >> "$R/log"
if [ "$1" = show ] && [ "$2" = -p ] && [ "$3" = ActiveState ] && [ "$4" = --value ]; then
    case "$5" in
    mld-firstboot.service) echo "$FB_STATE" ;;
    dnf5-automatic.service|apt-daily-upgrade.service) echo "$AU_STATE" ;;
    *) echo inactive ;;
    esac
    exit 0
fi
[ "$1" = is-active ] && exit 3
exit 0
STUB
    printf '#!/bin/sh\nexit 0\n' > "$r/bin/loginctl"
    chmod +x "$r/bin/"*
    for d in fedora ubuntu; do
        printf 'CLIENT_DISTRO=%s\n' "$d" > "$r/etc/config.env"
        au_unit=dnf5-automatic.service; [ "$d" = ubuntu ] && au_unit=apt-daily-upgrade.service
        # fields: dnf-rc, firstboot state, updater state, expected output
        for c in "1 activating inactive reboot required, but mld-firstboot.service runs" \
                 "1 inactive activating reboot required, but $au_unit runs" \
                 "1 active inactive reboot required by" \
                 "0 activating inactive "; do
            read -r dc fb au exp_out <<< "$c"
            : > "$r/log"; rm -f "$r/reboot-required"
            if [ "$d" = ubuntu ] && [ "$dc" = 1 ]; then
                : > "$r/reboot-required"; echo pkgx > "$r/reboot-required.pkgs"; fi
            out=$(PATH="$r/bin:$PATH" R="$r" DNF_RC=$dc FB_STATE=$fb AU_STATE=$au CRYPTTAB="$r/crypttab" \
                bash "$r/reboot.sh" 2>&1); rc=$?
            [ $rc = 0 ] || bad+="$d/$c: exit $rc; "
            bad+=$(reboot_rule_check "$d/$c" "$exp_out" "$out" "$r/log")
        done
    done
    printf 'CLIENT_DISTRO=fedora\n' > "$r/etc/config.env"; rm -f "$r/etc/distro.sh"
    out=$(PATH="$r/bin:$PATH" R="$r" DNF_RC=1 bash "$r/reboot.sh" 2>&1) && bad+="missing distro.sh: no abort; "
    case "$out" in *"missing"*"client resume"*) ;; *) bad+="missing distro.sh: no message; " ;; esac
    grep -qF '$$(systemctl show -p ActiveState --value mld-firstboot.service)" != activating' \
        "$COPY/client/mld/update/dnf5-automatic-mld.conf" \
        || bad+="drop-in: ExecCondition lacks ActiveState, activating or the double dollar; "
    rm -rf "$r"
    [ -z "$bad" ] && t_ok $n || t_fail $n "$bad"
}

sssd_authselect_fedora() {
    local n=sssd_authselect_fedora r d cur bad="" log
    r=$(mktemp -d "$TMPDIR/sssd.XXXX")
    for d in "fedora local" "fedora custom/mld" "fedora sssd with-mkhomedir" "ubuntu -"; do
        read -r distro cur <<<"$d"
        log=$(CLIENT_DISTRO=$distro CUR="$cur" PROBE_USER=u bash -c '
            install() { :; }; systemctl() { :; }; sleep() { :; }; phase() { :; }
            fail() { echo "fail $*"; exit 1; }
            authselect() { if [ "$1" = current ]; then echo "$CUR"; else echo "authselect $*"; fi; }
            getent() { echo "getent $*"; }
            . "$1"; phase_sssd' _ "$COPY/client/mld/ad/phase.sh" 2>&1)
        case "$d" in
        "fedora local")
            [ "$(printf '%s\n' "$log" | grep -m1 -E '^(authselect|getent)')" = "authselect select sssd --force" ] \
                || bad+="local: no authselect select sssd before getent ($log); " ;;
        *) grep -q '^authselect' <<<"$log" && bad+="$d: authselect called ($log); " ;;
        esac
    done
    rm -rf "$r"
    [ -z "$bad" ] && t_ok $n || t_fail $n "$bad"
}

qemu_ga_unconfined_fedora() {
    local n=qemu_ga_unconfined_fedora w d want bad="" k="$COPY/.stage/cidata/ks.cfg"
    w=$(mktemp -d "$TMPDIR/qga.XXXX"); mkdir -p "$w/bin"
    cp "$SRC/guest-exec.sh" "$w/"
    cat > "$w/bin/virsh" <<'STUB'
#!/bin/sh
for a; do last=$a; done
case "$last" in
*guest-exec-status*) echo '{"return":{"exited":true,"exitcode":0}}' ;;
*) printf '%s\n' "$last" > "$(dirname "$0")/../req.json"; echo '{"return":{"pid":7}}' ;;
esac
STUB
    chmod +x "$w/bin/virsh"
    for d in fedora ubuntu ""; do
        printf 'LIBVIRT_URI=test:///default\nCLIENT_VM=c\nDC_VM=d\n' > "$w/lab.env"
        [ -z "$d" ] || printf 'CLIENT_DISTRO=%s\n' "$d" >> "$w/lab.env"
        want=/bin/bash; [ "$d" = fedora ] && want=/usr/libexec/mld/qemu-ga-run
        ( unset CLIENT_DISTRO; PATH="$w/bin:$PATH" "$w/guest-exec.sh" client true ) >/dev/null 2>&1 \
            || bad+="${d:-none}: guest-exec failed; "
        [ "$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["arguments"]["path"])' \
            "$w/req.json" 2>&1)" = "$want" ] \
            || bad+="${d:-none}: path is not $want; "
    done
    rm -rf "$w"
    grep -qx 'virt_qemu_ga_run_unconfined on' "$COPY/client/mld/selinux/booleans.list" || bad+="no boolean; "
    grep -qx '/usr/libexec/mld/qemu-ga-run virt_qemu_ga_unconfined_exec_t' "$COPY/client/mld/selinux/fcontexts.list" \
        || bad+="no fcontext; "
    grep -qE '^selinux/qemu-ga-run.sh +/usr/libexec/mld/qemu-ga-run +755 +fedora$' "$COPY/client/mld/install.list" \
        || bad+="no install.list row; "
    fedora_render || { t_fail $n "client iso failed"; return; }
    grep -q 'selinux/booleans.list | while read -r name val; do semanage boolean -N -m "--$val" "$name"; done$' "$k" \
        || bad+="ks: no booleans; "
    grep -q 'selinux/fcontexts.list | while read -r re type; do semanage fcontext -N -a -t "$type" "$re"; done$' "$k" \
        || bad+="ks: no fcontexts; "
    grep -q '^restorecon -R .* /usr/libexec/mld$' "$k" || bad+="ks: no restorecon of /usr/libexec/mld; "
    [ -x "$COPY/.stage/cidata/mld/selinux/qemu-ga-run.sh" ] || bad+="CIDATA: no executable wrapper; "
    rm -f "$COPY/.stub-calls.log" "$COPY/.stub-calls.log.full"
    ( cd "$COPY" && STUB_OS_ID=fedora ./build.sh client resume >"$COPY/.out.log" 2>"$COPY/.err.log" ) \
        || bad+="resume failed: $(tail -n 2 "$COPY/.err.log"); "
    awk '/install -D/ { i = 1 }
         /^--- end$/ { if (i && !u) bad = 1; i = 0; u = 0; s = 0; next }
         s == 1 && /^umask 022$/ { u = 1 }
         { s++ }
         END { exit !(bad == 0 && NR > 0) }' \
        "$COPY/.stub-calls.log.full" 2>/dev/null || bad+="resume: a file snippet without umask 022 as second line; "
    [ -z "$bad" ] && t_ok $n || t_fail $n "$bad"
}

chrome_repo_fedora() {
    local n=chrome_repo_fedora r c bad="" out
    r=$(mktemp -d "$TMPDIR/chr.XXXX")
    mkdir -p "$r/cfg/apps"
    cp "$COPY"/client/mld/apps/{google-chrome.repo,google-linux-signing.asc} "$r/cfg/apps/"
    sed -e "s#/etc/#$r/etc/#g" -e "s#/usr/#$r/usr/#g" "$COPY/client/mld/apps/phase.sh" > "$r/phase.sh"
    for c in stock stock-old none; do
        rm -rf "$r/etc" "$r/usr" "$r/log"; mkdir -p "$r/etc/yum.repos.d"
        case "$c" in stock*)
            mkdir -p "$r/usr/share/dnf5/repos.d"
            printf '[google-chrome]\nname=google-chrome\nenabled=0\n' \
                > "$r/usr/share/dnf5/repos.d/google-chrome.repo" ;;
        esac
        [ "$c" != stock-old ] || cp "$r/cfg/apps/google-chrome.repo" "$r/etc/yum.repos.d/"
        out=$(CLIENT_DISTRO=fedora CFG="$r/cfg" R="$r" bash -c '
            rpm() { :; }; ln() { :; }; phase() { :; }; fail() { echo "fail $*"; exit 1; }
            dnf() { echo "dnf $*" >> "$R/log"; }
            pkg_install() { echo "pkg_install $*" >> "$R/log"; }
            . "$R/phase.sh"; phase_browsers' 2>&1) || { bad+="$c: $out; "; continue; }
        case "$c" in
        stock*)
            grep -qx 'dnf config-manager setopt google-chrome.enabled=1' "$r/log" || bad+="$c: stock repo not enabled; "
            [ ! -e "$r/etc/yum.repos.d/google-chrome.repo" ] || bad+="$c: second google-chrome repo file; " ;;
        none)
            cmp -s "$r/cfg/apps/google-chrome.repo" "$r/etc/yum.repos.d/google-chrome.repo" \
                || bad+="none: our repo file not installed; "
            grep -q 'config-manager' "$r/log" && bad+="none: config-manager called; " ;;
        esac
        grep -q '^pkg_install firefox google-chrome-stable$' "$r/log" || bad+="$c: browsers not installed; "
    done
    rm -rf "$r"
    [ -z "$bad" ] && t_ok $n || t_fail $n "$bad"
}

# fedora-45-CHECKSUM: the real signed file. fedora-45-primary.gpg: the key of fedora-gpg-keys-45-1 (gpg --dearmor).
fedora_sums_signed_only() {
    local n=fedora_sums_signed_only d bad="" c out iso=Fedora-Everything-netinst-x86_64-45-1.4.iso
    local good=42abc36792f91575b2f541db19110cc661864819031e57cd5f5c9ec764ebbddf bad_sum
    command -v gpgv >/dev/null || { t_skip $n "gpgv not installed"; return; }
    bad_sum=$(printf 'b%.0s' $(seq 64))
    d=$(mktemp -d "$TMPDIR/sums.XXXX"); mkdir -p "$d/media" "$d/bin"
    cp "$COPY/tests/fixtures/fedora-45-primary.gpg" "$d/media/fedora.gpg"
    for c in outside tampered twice; do
        case "$c" in
        outside)
            { printf 'SHA256 (%s) = %s\n' "$iso" "$bad_sum"; cat "$COPY/tests/fixtures/fedora-45-CHECKSUM"; } \
                > "$d/CHECKSUM" ;;
        tampered) sed "s/= $good/= $bad_sum/" "$COPY/tests/fixtures/fedora-45-CHECKSUM" > "$d/CHECKSUM" ;;
        twice)
            # Needs a test key: gpg-agent cannot start where Unix sockets are not allowed (Claude sandbox).
            mkdir -p "$d/gnupg"; chmod 700 "$d/gnupg"
            if ! GNUPGHOME="$d/gnupg" gpg --batch --quiet --passphrase '' \
                    --quick-gen-key 'MLD Test <t@test>' ed25519 sign 1d >/dev/null 2>&1; then
                echo "skip $n/twice: gpg cannot make a test key" >&2; continue
            fi
            GNUPGHOME="$d/gnupg" gpg --batch --export > "$d/media/fedora.gpg"
            printf 'SHA256 (%s) = %s\nSHA256 (%s) = %s\n' "$iso" "$good" "$iso" "$bad_sum" \
                | GNUPGHOME="$d/gnupg" gpg --batch --quiet --clearsign > "$d/CHECKSUM"
            GNUPGHOME="$d/gnupg" gpgconf --kill gpg-agent 2>/dev/null ;;
        esac
        printf '#!/bin/sh\nwhile [ "$1" != -o ]; do shift; done; cp "%s" "$2"\n' "$d/CHECKSUM" > "$d/bin/curl"
        chmod +x "$d/bin/curl"
        : > "$d/checksums.sha256"
        out=$(PATH="$d/bin:$PATH" HERE="$d" MEDIA_DIR="$d/media" FEDORA_SUMS_URL=https://x/CHECKSUM \
            FEDORA_ISO="$d/$iso" bash -c '
            log() { :; }; warn() { :; }; die() { echo "die: $*"; exit 1; }
            . "$1"; . "$2"; fetch_fedora_sums' _ "$COPY/lib/common.sh" "$COPY/lib/host.sh" 2>&1)
        case "$c" in
        outside) [ "$(cat "$d/checksums.sha256")" = "$good  $iso" ] \
                     || bad+="outside: pinned '$(cat "$d/checksums.sha256")' ($out); " ;;
        tampered) [[ "$out" == *"bad signature"* && ! -s "$d/checksums.sha256" ]] \
                      || bad+="tampered: not refused ($out); " ;;
        twice) [[ "$out" == *"want one SHA256 line"* && ! -s "$d/checksums.sha256" ]] \
                   || bad+="twice: not refused ($out); " ;;
        esac
    done
    rm -rf "$d"
    [ -z "$bad" ] && t_ok $n || t_fail $n "$bad"
}

fedora_pkg_names() {
    local n=fedora_pkg_names out r bad=""
    r=$(mktemp -d "$TMPDIR/pkgs.XXXX")
    mkdir -p "$r/client/mld/x"
    cp "$COPY/client/ks.cfg.tmpl" "$r/client/"
    printf '%s\n' 'case "$CLIENT_DISTRO" in' 'ubuntu) pkg_install ubuntu-only-pkg ;;' \
        'fedora) pkg_install fedora-test-a ;;' 'esac' \
        'if [ "$CLIENT_DISTRO" = ubuntu ]; then pkg_install ubuntu-only-pkg; fi' \
        'only_u() {' '    pkg_install ubuntu-only-pkg' '}' \
        'case "$CLIENT_DISTRO" in' 'ubuntu) only_u ;;' 'esac' 'pkg_install fedora-test-b' > "$r/client/mld/x/phase.sh"
    out=$(python3 -I "$COPY/tests/fedora-pkgs.py" "$r" 2>&1 | cut -f1)
    grep -qx fedora-test-a <<<"$out" && grep -qx fedora-test-b <<<"$out" || bad+="self-test: Fedora names not found; "
    grep -q ubuntu-only-pkg <<<"$out" && bad+="self-test: Ubuntu-only name counted; "
    sed -i 's/^%end$/semodule-utils\n%end/' "$r/client/ks.cfg.tmpl"
    rm -rf "$r/client/mld/x"
    out=$(python3 -I "$COPY/tests/fedora-pkgs.py" "$r" "$COPY/tests/fixtures/fedora-pkgs.txt" 2>&1) \
        && bad+="self-test: semodule-utils accepted; "
    rm -rf "$r"
    out=$(python3 -I "$COPY/tests/fedora-pkgs.py" "$COPY" "$COPY/tests/fixtures/fedora-pkgs.txt" 2>&1) \
        || bad+="$(tr '\n' '|' <<<"$out")"
    [ -z "$bad" ] && t_ok $n || t_fail $n "$bad"
}

# cfg_eval EXPR: loads the test lab.env and lib/config.sh, then prints EXPR. A die message goes to stdout.
cfg_eval() {
    (cd "$COPY" && HERE=$COPY STAGE=$COPY/.stage && set -a && . ./lab.env && set +a \
        && die() { echo "DIE: $*"; exit 1; } && . ./lib/config.sh && eval "echo \"$1\"")
}

idp_invalid() {
    local n=idp_invalid
    write_lab; set_lab IDP samba
    if build_in_copy client iso; then t_fail $n "exit 0"; return; fi
    grep -q 'IDP must be windows or freeipa' "$COPY/.err.log" && t_ok $n \
        || t_fail $n "no message: $(tail -n 2 "$COPY/.err.log")"
}

idp_derived_values() {
    local n=idp_derived_values e='$IDP $PKI_ENROLL $HOME_MODE $O365_APPS $IDM_GROUP' out bad=""
    write_lab; set_lab IDP ""
    out=$(cfg_eval "$e"); [ "$out" = "windows web cifs 1 LinuxUsers" ] || bad+="windows default: $out; "
    set_lab CIFS_HOME 0
    out=$(cfg_eval "$e"); [ "$out" = "windows web local 1 LinuxUsers" ] || bad+="windows CIFS_HOME=0: $out; "
    write_lab; set_lab IDP freeipa
    out=$(cfg_eval "$e"); [ "$out" = "freeipa ipa nfs 0 linuxusers" ] || bad+="freeipa default: $out; "
    set_lab NFS_HOME 0; set_lab O365_APPS 1; set_lab PKI_ENROLL none
    out=$(cfg_eval "$e"); [ "$out" = "freeipa none local 1 linuxusers" ] || bad+="freeipa overrides: $out; "
    set_lab PKI_ENROLL web
    out=$(cfg_eval "$e"); [[ "$out" == "DIE: IDP=freeipa: PKI_ENROLL must be ipa or none"* ]] \
        || bad+="freeipa web accepted: $out; "
    write_lab; set_lab PKI_ENROLL ipa
    out=$(cfg_eval "$e"); [[ "$out" == "DIE: PKI_ENROLL must be web, dcom or none"* ]] \
        || bad+="windows ipa accepted: $out; "
    write_lab; set_lab O365_APPS 2
    out=$(cfg_eval "$e"); [[ "$out" == "DIE: O365_APPS must be 0 or 1"* ]] || bad+="O365_APPS=2 accepted: $out; "
    [ -z "$bad" ] && t_ok $n || t_fail $n "$bad"
}

idp_config_vars() {
    local n=idp_config_vars out bad=""
    out=$(HERE=$COPY; IDP=windows; . "$COPY/lib/client.sh"
        idp_vars DOMAIN JOIN_USER LINUX_OU CA_NAME DOMAIN_DN PKI_ENROLL | tr '\n' ' ')
    [ "$out" = "DOMAIN JOIN_USER LINUX_OU CA_NAME DOMAIN_DN PKI_ENROLL " ] || bad+="windows: $out; "
    out=$(HERE=$COPY; IDP=freeipa; . "$COPY/lib/client.sh"
        idp_vars DOMAIN JOIN_USER LINUX_OU CA_NAME DOMAIN_DN PKI_ENROLL | tr '\n' ' ')
    [ "$out" = "DOMAIN PKI_ENROLL IDP HOME_MODE NFS_HOME O365_APPS IDM_GROUP " ] || bad+="freeipa: $out; "
    [ -z "$bad" ] && t_ok $n || t_fail $n "$bad"
}

installlist_idp_tags() {
    local n=installlist_idp_tags l="$COPY/.taglist" out bad="" combo
    mkdir -p "$COPY/.tagtest/client/mld"
    printf '%s\n' '# comment' 'a /a 644' 'b /b 644 all' 'c /c 644 ubuntu' 'd /d 644 windows' 'e /e 644 freeipa' \
        'f /f 644 fedora+freeipa' 'g /g 644 ubuntu+windows' > "$COPY/.tagtest/client/mld/install.list"
    for combo in ubuntu:windows ubuntu:freeipa fedora:windows fedora:freeipa; do
        out=$(HERE=$COPY/.tagtest; CLIENT_DISTRO=${combo%:*}; IDP=${combo#*:}; . "$COPY/lib/client.sh"
            install_list | cut -d' ' -f1 | tr -d '\n')
        printf '%s=%s\n' "$combo" "$out" >> "$l"
    done
    out=$(tr '\n' ' ' < "$l"); rm -rf "$COPY/.tagtest" "$l"
    [ "$out" = "ubuntu:windows=abcdg ubuntu:freeipa=abce fedora:windows=abd fedora:freeipa=abef " ] \
        || bad+="install_list: $out; "
    out=$(HERE=$SRC; CLIENT_DISTRO=fedora; IDP=freeipa; . "$COPY/lib/client.sh"; install_list_file \
        | awk '!/^[[:space:]]*#/ && NF != 3 && NF > 0 { print }')
    [ -z "$out" ] || bad+="install_list_file has lines with other than 3 columns: $out; "
    [ -z "$bad" ] && t_ok $n || t_fail $n "$bad"
}

freeipa_stubs_stop() {
    local n=freeipa_stubs_stop bad=""
    write_lab; set_lab IDP freeipa
    rm -f "$COPY/.stub-calls.log"
    build_in_copy client iso || bad+="client iso: $(tail -n 1 "$COPY/.err.log"); "
    ! grep -q 'odj-provision\|djoin' "$COPY/.stub-calls.log" 2>/dev/null || bad+="client iso called odj-provision; "
    grep -qx 'IDP=freeipa' "$COPY/.stage/cidata/mld/config.env" || bad+="config.env has no IDP=freeipa; "
    ! grep -q '^JOIN_USER=\|^LINUX_OU=\|^CA_NAME=\|^DOMAIN_DN=' "$COPY/.stage/cidata/mld/config.env" \
        || bad+="config.env has AD-only names; "
    # No "dc vm" here: it calls virt-install, which can reach the real libvirt socket.
    if build_in_copy dc set-passwords; then bad+="dc set-passwords: exit 0; "
    else grep -q 'dc set-passwords: IDP=windows only' "$COPY/.err.log" \
             || bad+="dc set-passwords: $(tail -n 1 "$COPY/.err.log"); "; fi
    [ -z "$bad" ] && t_ok $n || t_fail $n "$bad"
}

UBUNTU_TESTS=(ubuntu_baseline_unchanged distro_default_ubuntu distro_invalid resume_distro_mismatch installlist_filter
    distro_sh_functions verify_checks_ubuntu)
FEDORA_TESTS=(cert_ca_trust verify_checks_fedora reboot_rule_fedora admin_pw_fedora verify_facts_env kernel_install_hook
    fedora_paths_used distro_fedora_config ks_render ks_secret_roundtrip ks_newline_rejected fedora_grub_patched
    hw_ks_fedora ks_validate authselect_profile_edit selinux_lists_parse selinux_te_compiles selinux_avc_report
    selinux_phase_logic fedora_repo_keys no_dpkg_on_fedora_paths autoenroll_module_path fedora_desktop_rules
    fedora_pkg_names sssd_authselect_fedora qemu_ga_unconfined_fedora chrome_repo_fedora fedora_sums_signed_only)
freeipa_dc_iso() {
    local n=freeipa_dc_iso d="$COPY/.stage/ipa-iso" bad="" out f
    write_lab; set_lab IDP freeipa
    build_in_copy dc iso || { t_fail $n "dc iso failed: $(tail -n 3 "$COPY/.err.log")"; return; }
    grep -q -- '--ip=10.110.0.2 ' "$d/ks.cfg" || bad+="ks.cfg: no static DC_IP; "
    grep -q -- '--hostname=dc1.mld.contoso.com ' "$d/ks.cfg" || bad+="ks.cfg: hostname not the lower-case DC_FQDN; "
    ! grep -q '@@' "$d/ks.cfg" || bad+="ks.cfg: unrendered @@; "
    out=$(set +u; . "$d/provision/config.env"
        echo "$ADMIN_PW|$IPA_DM_PW|$LAB_USER_PW|$IDM_GROUP|$REALM|$REVERSE_ZONE|$NTP_POOL")
    local want="Test-Secret-1|Test-Secret-1|Test-Secret-1|linuxusers|MLD.CONTOSO.COM|0.110.10.in-addr.arpa|pool.ntp.org"
    [ "$out" = "$want" ] \
        || bad+="config.env: $out; "
    out=$(iso_ls "$COPY/.stage/ipa-provision.iso" | tr '\n' ' ')
    for f in /ks.cfg /mld-ipa-provision.service /qemu-ga-run.sh /provision/config.env /provision/run.sh \
             /provision/01-install.sh /provision/02-directory.sh /provision/03-nfs.sh /provision/04-pki.sh \
             /provision/05-policy.sh; do
        [[ " $out " == *" '$f' "* || " $out " == *" $f "* ]] || bad+="ipa-provision.iso has no $f; "
    done
    [ "$(stat -c %a "$COPY/.stage/ipa-provision.iso")" = 600 ] || bad+="ipa-provision.iso is not mode 600; "
    out=$(iso_cat "$COPY/.stage/fedora-ipa-ks.iso" /EFI/BOOT/grub.cfg)
    grep -q 'inst.ks=hd:LABEL=IPAPROV:/ks.cfg' <<<"$out" || bad+="fedora-ipa-ks.iso: no kickstart entry; "
    [ -f "$COPY/.stage/dc-iso.inputs" ] || bad+="no dc-iso.inputs stamp; "
    set_lab ADMIN_PW short
    if build_in_copy dc iso; then bad+="short ADMIN_PW accepted; "
    else grep -q 'ADMIN_PW: FreeIPA needs at least 8 characters' "$COPY/.err.log" \
             || bad+="short ADMIN_PW: $(tail -n 1 "$COPY/.err.log"); "; fi
    [ -z "$bad" ] && t_ok $n || t_fail $n "$bad"
}

guest_exec_routing() {
    local n=guest_exec_routing t bad="" idp
    t=$(mktemp -d "$TMPDIR/gx.XXXX")
    cp "$SRC/guest-exec.sh" "$t/"
    mkdir -p "$t/bin"
    cat > "$t/bin/virsh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
    *guest-exec-status*) echo '{"return":{"exited":true,"exitcode":0,"out-data":""}}' ;;
    *) printf '%s\n' "${@: -1}" >> "$(dirname "$0")/../req.log"; echo '{"return":{"pid":7}}' ;;
esac
STUB
    chmod +x "$t/bin/virsh"
    for idp in windows freeipa; do
        printf 'LIBVIRT_URI=qemu:///x\nDC_VM=d\nCLIENT_VM=c\nCLIENT_DISTRO=ubuntu\nIDP=%s\n' "$idp" > "$t/lab.env"
        PATH="$t/bin:$PATH" "$t/guest-exec.sh" dc 'echo hi' >/dev/null 2>&1 || bad+="$idp: guest-exec failed; "
    done
    PATH="$t/bin:$PATH" "$t/guest-exec.sh" client 'echo hi' >/dev/null 2>&1 || bad+="client: guest-exec failed; "
    mapfile -t paths < <(python3 -c \
        'import json,sys; [print(json.loads(l)["arguments"]["path"]) for l in open(sys.argv[1])]' "$t/req.log")
    rm -rf "$t"
    [ "${paths[*]}" = "powershell.exe /usr/libexec/mld/qemu-ga-run /bin/bash" ] || bad+="paths: ${paths[*]}; "
    local out
    out=$(cd "$COPY" && rm -f .stub-calls.log.full && LIBVIRT_URI=qemu:///x HERE=$COPY IDP=freeipa \
        && . ./lib/common.sh && guest_run dc ipa/guest/status.sh 'A=x y' >/dev/null && head -n 1 .stub-calls.log.full)
    [ "$out" = 'A=x\ y' ] || bad+="guest_run dc freeipa prefix: $out; "
    [ -z "$bad" ] && t_ok $n || t_fail $n "$bad"
}

ipa_runner() {
    local n=ipa_runner t bad=""
    t=$(mktemp -d "$TMPDIR/ipa.XXXX")
    mkdir -p "$t/lib" "$t/state" "$t/bin"
    printf 'ADMIN_PW=x\n' > "$t/config.env"
    local p
    for p in 01-install 02-directory 03-nfs 04-pki 05-policy; do
        printf 'echo %s >> "%s/ran"\n' "$p" "$t" > "$t/lib/$p.sh"
    done
    printf 'ipa_q group-add linuxusers\n' >> "$t/lib/02-directory.sh"
    printf 'false\n' >> "$t/lib/03-nfs.sh"
    # Stub ipa: "already exists" for group-add (ipa_q accepts it), an error for anything else.
    printf '#!/bin/sh\n%s\necho boom; exit 1\n' \
        'case "$1" in group-add) echo "ipa: ERROR: group with name \"$2\" already exists"; exit 1 ;; esac' \
        > "$t/bin/ipa"
    chmod +x "$t/bin/ipa"
    local env=(PATH="$t/bin:$PATH" MLD_IPA_STATE="$t/state" MLD_IPA_LIB="$t/lib" MLD_IPA_CONF="$t/config.env")
    env "${env[@]}" bash "$SRC/ipa/provision/run.sh" && bad+="run 1: exit 0 with a failing phase; "
    grep -q 'phase 3: line' "$t/state/FAILED" 2>/dev/null || bad+="run 1: FAILED has no phase 3 line; "
    [ "$(cat "$t/state/phase")" = 3 ] || bad+="run 1: phase is not 3; "
    [ ! -e "$t/state/DONE" ] || bad+="run 1: DONE exists; "
    [ "$(tr '\n' ' ' < "$t/ran")" = "01-install 02-directory 03-nfs " ] \
        || bad+="run 1 ran: $(tr '\n' ' ' < "$t/ran"); "
    sed -i '/^false$/d' "$t/lib/03-nfs.sh"; : > "$t/ran"
    env "${env[@]}" bash "$SRC/ipa/provision/run.sh" || bad+="run 2: exit $?; "
    [ "$(tr '\n' ' ' < "$t/ran")" = "03-nfs 04-pki 05-policy " ] || bad+="run 2 ran: $(tr '\n' ' ' < "$t/ran"); "
    [ -s "$t/state/DONE" ] && [ ! -e "$t/state/FAILED" ] || bad+="run 2: no DONE or FAILED stays; "
    printf 'ipa_q user-add bob\n' > "$t/lib/05-policy.sh"; echo 5 > "$t/state/phase"; rm -f "$t/state/DONE"
    env "${env[@]}" bash "$SRC/ipa/provision/run.sh" && bad+="run 3: ipa error accepted; "
    grep -q boom "$t/state/provision.log" || bad+="run 3: ipa error text not in the log; "
    rm -rf "$t"
    local f
    for f in "$SRC"/ipa/provision/*.sh "$SRC"/ipa/guest/*.sh; do bash -n "$f" || bad+="syntax: $f; "; done
    [ -z "$bad" ] && t_ok $n || t_fail $n "$bad"
}

freeipa_client_iso() {
    local n=freeipa_client_iso c="$COPY/.stage/cidata" bad="" distro
    for distro in fedora ubuntu; do
        write_lab; set_lab IDP freeipa; set_lab CLIENT_DISTRO "$distro"; set_lab CLIENT_DE gnome
        rm -f "$COPY/.stub-calls.log.full"
        build_in_copy client iso || { bad+="$distro: client iso failed: $(tail -n 2 "$COPY/.err.log"); "; continue; }
        [ -s "$c/mld/ipa-otp.txt" ] || bad+="$distro: no mld/ipa-otp.txt; "
        [ ! -e "$c/mld/odj.txt" ] || bad+="$distro: mld/odj.txt on CIDATA; "
        [ "$(cat "$c/mld/ipa-otp.txt" 2>/dev/null)" = "$(cat "$COPY/.stage/join/lnx01.otp" 2>/dev/null)" ] \
            || bad+="$distro: OTP on CIDATA differs from .stage/join/lnx01.otp; "
        grep -q 'FQDN=lnx01.mld.contoso.com' "$COPY/.stub-calls.log.full" \
            || bad+="$distro: host-add not called for lnx01; "
        grep -q '^OTP=' "$COPY/.stub-calls.log.full" || bad+="$distro: host-add got no OTP; "
        [ -f "$c/mld/ipa/phase.sh" ] || bad+="$distro: no mld/ipa/phase.sh; "
        [ ! -e "$c/mld/gpo/phase.sh" ] && [ ! -e "$c/mld/home/home-umount.sh" ] \
            || bad+="$distro: Windows-only files on CIDATA; "
        [ ! -e "$c/mld/ad/sssd.conf" ] || bad+="$distro: AD template ad/sssd.conf on CIDATA; "
        bad+=$(freeipa_client_iso_install "$distro" "$c")
    done
    [ -z "$bad" ] && t_ok $n || t_fail $n "$bad"
}

# freeipa_client_iso_install DISTRO CIDATA: prints the problems of the IDP=freeipa kickstart or user-data.
freeipa_client_iso_install() {
    local distro=$1 c=$2 bad="" p
    local f="$c/ks.cfg"; [ "$distro" = fedora ] || f="$c/user-data"
    for p in sssd-ad realmd adcli samba-common-tools samba-common-bin pam_mount libpam-mount cifs-utils \
             python3-impacket; do
        ! grep -qE "^[[:space:]]*(- )?$p[[:space:]]*$" "$f" || bad+="$distro: AD package $p in $(basename "$f"); "
    done
    grep -qE '^[[:space:]]*(- )?autofs[[:space:]]*$' "$f" || bad+="$distro: no autofs in $(basename "$f"); "
    grep -q 'certmonger' "$f" || bad+="$distro: certmonger removed; "
    grep -q '/etc/mld/ipa-otp.txt' "$f" && ! grep -q '/etc/mld/odj.txt' "$f" \
        || bad+="$distro: chmod line still names odj.txt; "
    if [ "$distro" = fedora ]; then
        grep -qx 'freeipa-client' "$f" || bad+="fedora: no freeipa-client in %packages; "
    else
        python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "$f" 2>/dev/null \
            || bad+="ubuntu: user-data is no YAML; "
    fi
    printf '%s' "$bad"
}

freeipa_client_logic() {
    local n=freeipa_client_logic bad="" out
    # firstboot: the ipa, gpo and policy topics are optional, the join and the GPO/policy phase follow IDP.
    local fb="$SRC/client/mld/firstboot.sh"
    grep -q 'case "\$topic" in selinux|gpo|ipa|policy)' "$fb" || bad+="firstboot: optional topics; "
    grep -q 'then phase_gpo; else phase_policy; fi' "$fb" || bad+="firstboot: no phase_policy; "
    # IDP=freeipa PKI: no AD-only packages or names, the IPA requests in autoenroll.py.
    grep -q 'if \[ "${IDP:-windows}" = windows \]; then' "$SRC/client/mld/cert/phase.sh" \
        || bad+="cert: no IDP gate; "
    grep -q '"mld-ipa-machine"' "$SRC/client/mld/cert/autoenroll.py" || bad+="autoenroll: no IPA machine request; "
    grep -q '^from impacket' "$SRC/client/mld/cert/autoenroll.py" \
        && bad+="autoenroll: impacket imported at the top; "
    awk '$1 ~ /^policy\// && $4 != "freeipa" { bad = 1 } END { exit bad }' "$SRC/client/mld/install.list" \
        || bad+="install.list: policy files not tagged freeipa; "
    grep -q 'phase_join_ipa' "$SRC/client/mld/firstboot.sh" || bad+="firstboot: no phase_join_ipa; "
    grep -q 'ipa-otp.txt' "$SRC/client/mld/firstboot.sh" || bad+="firstboot: OTP not shredded; "
    # The O365 pin filter: O365_APPS=0 drops mld-o365-* pins.
    out=$(set +eu; CFG=$(mktemp -d "$TMPDIR/pins.XXXX"); mkdir -p "$CFG/desktop"
        printf '%s\n' mld-o365-outlook.desktop google-chrome.desktop @firefox > "$CFG/desktop/pins.list"
        O365_APPS=0; CLIENT_DE=gnome; CLIENT_DISTRO=ubuntu
        . "$SRC/client/mld/desktop/phase.sh"
        desktop_dconf_profile() { :; }; install() { :; }; dconf() { :; }; rm() { :; }
        # The function writes the dconf file: send it to stdout through a fake path.
        sed -e 's|/etc/dconf/db/local.d/10-mld-desktop|/dev/stdout|' <(declare -f desktop_pins) > "$CFG/f.sh"
        . "$CFG/f.sh"
        desktop_pins 2>/dev/null; command rm -rf "$CFG")
    [[ "$out" == *"favorite-apps=['google-chrome.desktop', 'firefox.desktop']"* ]] \
        || bad+="pins with O365_APPS=0: $out; "
    local f
    for f in "$SRC"/client/mld/ipa/phase.sh "$SRC"/client/mld/home/phase.sh "$SRC"/client/mld/firstboot.sh \
             "$SRC"/ipa/guest/host-add.sh; do
        bash -n "$f" || bad+="syntax: $f; "
    done
    [ -z "$bad" ] && t_ok $n || t_fail $n "$bad"
}

FREEIPA_TESTS=(idp_invalid idp_derived_values idp_config_vars installlist_idp_tags freeipa_stubs_stop freeipa_dc_iso
    guest_exec_routing ipa_runner freeipa_client_iso freeipa_client_logic)

main() {
    TMPDIR="${TMPDIR:-/tmp}"; export TMPDIR
    if [ "${1:-}" = --record-baseline ]; then record_baseline; exit 0; fi
    local set=all; case "${1:-}" in ubuntu|fedora|freeipa|all) set=$1; shift ;; esac
    local tests=("$@")
    if [ ${#tests[@]} -eq 0 ]; then
        case "$set" in
            ubuntu) tests=("${UBUNTU_TESTS[@]}") ;;
            fedora) tests=("${FEDORA_TESTS[@]}") ;;
            freeipa) tests=("${FREEIPA_TESTS[@]}") ;;
            all)    tests=("${UBUNTU_TESTS[@]}" "${FEDORA_TESTS[@]}" "${FREEIPA_TESTS[@]}") ;;
        esac
    fi
    make_copy
    local t
    for t in "${tests[@]}"; do
        if declare -F "$t" >/dev/null; then "$t"; else t_fail "$t" "unknown test"; fi
    done
    [ "$FAILS" -eq 0 ]
}

main "$@"
