# Sourced by build.sh. Needs lab.env loaded, $HERE and $STAGE set.
# shellcheck shell=bash

VIRSH=(virsh -c "$LIBVIRT_URI")

log()  { printf '\033[1;32m[build]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[build]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[build]\033[0m %s\n' "$*" >&2; exit 1; }

media_files() {
    if [ "${IDP:-windows}" = freeipa ]; then
        printf '%s\n' "$FEDORA_ISO"
        [ "$CLIENT_ISO" = "$FEDORA_ISO" ] || printf '%s\n' "$CLIENT_ISO"
    else
        printf '%s\n' "$WINSERVER_ISO" "$VIRTIO_ISO" "$CLIENT_ISO"
    fi
}

# The source ISO is too large to hash at each run. Its size and time stand for its content.
iso_inputs() {
    local role=$1 dir=$1 f v files=(lab.env lib/common.sh lib/config.sh "lib/$1.sh")
    if [ "$role" = client ]; then
        files+=("${BRAND_LOGO:-client/mld/brand/logo.svg}")
        for f in "$STAGE/odj/${CLIENT_HOSTNAME^^}.txt" "$STAGE/join/${CLIENT_HOSTNAME,,}.otp" "$STAGE/sb/db.crt"; do
            [ ! -f "$f" ] || files+=("$f")
        done
    elif [ "${IDP:-windows}" = freeipa ]; then
        # The server ISO uses the Fedora remaster of lib/client.sh and the guest agent wrapper of the client.
        dir=ipa files=(lab.env lib/common.sh lib/config.sh lib/ipa.sh lib/client.sh client/mld/selinux/qemu-ga-run.sh)
    fi
    {
        find "$dir" -type f -not -path '*/__pycache__/*' -print0 | sort -z | xargs -0 sha256sum
        sha256sum "${files[@]}"
        [ "$dir" != ipa ] || stat -L -c '%n %s %Y' "$FEDORA_ISO" 2>/dev/null || echo "no $FEDORA_ISO"
        if [ "$role" = client ]; then
            stat -L -c '%n %s %Y' "$CLIENT_ISO" 2>/dev/null || echo "no $CLIENT_ISO"
            for v in CLIENT_DISTRO CLIENT_INSTALL_ISO CLIENT_HOSTNAME CLIENT_DE UKI UKI_TRUST ENROLL_TPM2 PKI_ENROLL \
                     CIFS_HOME SNX_RS BRAND_BG IDP NFS_HOME O365_APPS; do
                printf '%s=%q\n' "$v" "${!v-}"
            done
        fi
    } | sha256sum | cut -d' ' -f1
}

iso_stamp() { iso_inputs "$1" > "$STAGE/$1-iso.inputs"; }

# iso_current ROLE FILE...: the files exist and the last "ROLE iso" made them from the current inputs.
iso_current() {
    local role=$1 f; shift
    for f; do [ -f "$f" ] || return 1; done
    [ "$(cat "$STAGE/$role-iso.inputs" 2>/dev/null)" = "$(iso_inputs "$role")" ]
}

sum_for() { awk -v n="$1" '$2 == n { print $1 }' "$HERE/checksums.sha256"; }

# checksums.sha256 names files by basename.
verify_one() {
    local f="$1" want
    [ -f "$f" ] || { printf '  MISSING %s\n' "$f"; return 1; }
    want=$(sum_for "$(basename "$f")")
    [ -n "$want" ] || { printf '  NO-SUM  %s  (./build.sh pin)\n' "$f"; return 1; }
    if [ "$(sha256sum "$f" | cut -d' ' -f1)" = "$want" ]; then
        printf '  ok      %s\n' "$(basename "$f")"
    else
        printf '  BAD-SUM %s\n' "$f"; return 1
    fi
}

verify_media() {
    local f bad=0
    while IFS= read -r f; do verify_one "$f" || bad=1; done < <(media_files)
    return "$bad"
}

# Trust on first use: Microsoft and the virtio-win project publish no ISO checksum.
# Records the sum of each present file that has no line yet. Commit checksums.sha256 after this.
pin_media() {
    local f n
    while IFS= read -r f; do
        n=$(basename "$f")
        [ -f "$f" ] || continue
        [ -z "$(sum_for "$n")" ] || continue
        printf '%s  %s\n' "$(sha256sum "$f" | cut -d' ' -f1)" "$n" >> "$HERE/checksums.sha256"
        log "pinned $n"
    done < <(media_files)
}

fetch_one() {
    local dest="$1" url="$2"
    [ -f "$dest" ] && { log "have $(basename "$dest")"; return; }
    mkdir -p "$(dirname "$dest")"
    log "downloading $(basename "$dest") ..."
    curl -fL --retry 5 --retry-all-errors --progress-bar -o "$dest.part" "$url" \
        || die "download failed after retries: $url"
    mv "$dest.part" "$dest"
}

pool_path() {
    "${VIRSH[@]}" pool-dumpxml "$POOL" 2>/dev/null | sed -n 's:.*<path>\(.*\)</path>.*:\1:p' | head -1
}

# qemu:///system runs QEMU as $QEMU_USER. dynamic_ownership changes the owner of the image files only.
# The parent directories must let $QEMU_USER enter (x for others or an ACL entry).
# Prints each parent directory that blocks $QEMU_USER.
qemu_blocked_dirs() {
    local d="$1" u="${QEMU_USER:-libvirt-qemu}"
    case "$LIBVIRT_URI" in *:///session) return 0 ;; esac
    while [ ! -e "$d" ]; do d=$(dirname "$d"); done
    d=$(realpath "$d")
    while :; do
        if [ $(( 0$(stat -c %a "$d") & 1 )) -eq 0 ] \
            && ! getfacl -cp "$d" 2>/dev/null | grep -q "^user:$u:..x"; then
            printf '%s\n' "$d"
        fi
        [ "$d" = / ] && break
        d=$(dirname "$d")
    done
}

# Parent directories of the VM files that $QEMU_USER cannot enter (one per line, no duplicates).
qemu_blocked_all() {
    local d
    for d in "$POOL_DIR" "$MEDIA_DIR" "$STAGE"; do qemu_blocked_dirs "$d"; done | sort -u
}

# The setfacl command that opens the blocked directories. A tmpfs mount point (/run/media/$USER) loses
# the ACL at each host reboot. Then virsh start fails with "Permission denied" on the disk.
qemu_access_fix() { printf 'sudo setfacl -m u:%s:x%s' "${QEMU_USER:-libvirt-qemu}" "$(printf ' %q' "$@")"; }

require_qemu_access() {
    local -a blocked
    mapfile -t blocked < <(qemu_blocked_all)
    [ "${#blocked[@]}" -eq 0 ] \
        || die "${QEMU_USER:-libvirt-qemu} cannot enter:$(printf ' %s' "${blocked[@]}")." \
               "Run: $(qemu_access_fix "${blocked[@]}")"
}

# On btrfs, copy-on-write fragments a VM disk on every guest write.
# chattr +C has an effect only on files made after it is set.
# nocow PATH: 0 = +C set, 1 = CoW on, 2 = flags not readable.
nocow() {
    local flags
    flags=$( { lsattr -d "$1" 2>/dev/null || sudo -n lsattr -d "$1" 2>/dev/null; } | awk '{ print $1 }')
    [ -n "$flags" ] || return 2
    [[ "$flags" == *C* ]]
}

# Returns 1 if the pool dir is on btrfs with CoW, or the disk of VM $1 has CoW. Returns 3 if the flags are not readable.
nocow_problem() {
    local vm="$1" dir f rc unknown=""
    dir=$(pool_path)
    [ -n "$dir" ] || { echo "pool $POOL has no target path"; return 1; }
    [ "$(stat -f -c %T "$dir" 2>/dev/null)" = btrfs ] || return 0
    for f in "$dir" "$dir/${vm}.qcow2"; do
        [ "$f" = "$dir" ] || "${VIRSH[@]}" vol-info "$f" >/dev/null 2>&1 || continue
        nocow "$f"; rc=$?
        case "$rc" in
            0) ;;
            2) unknown="${unknown:+$unknown; }cannot read the flags of $f without root."
               unknown+=" Check with: sudo lsattr -d $f" ;;
            *) if [ "$f" = "$dir" ]; then
                   echo "$dir is on btrfs with CoW enabled. Run: sudo chattr +C $dir"
               else
                   echo "$f has CoW (made before chattr +C). Destroy the VM and build again"
               fi
               return 1 ;;
        esac
    done
    [ -z "$unknown" ] || { echo "$unknown"; return 3; }
}

require_nocow() {
    local why rc=0
    why=$(nocow_problem "$1") || rc=$?
    case "$rc" in 0) ;; 3) warn "$why" ;; *) die "$why" ;; esac
}

# Output first, then grep: with pipefail, "virsh | grep -q" fails when grep closes the pipe early (SIGPIPE).
pool_active() { local i; i=$("${VIRSH[@]}" pool-info "$POOL" 2>/dev/null) && grep -q '^State:.*running' <<<"$i"; }
net_active()  { local i; i=$("${VIRSH[@]}" net-info "$NET" 2>/dev/null) && grep -q '^Active:.*yes' <<<"$i"; }

# The pool dir is under /run/media/$USER. At host boot, libvirt can try the pool autostart before the
# mount is there, so the pool stays inactive. libvirt also keeps the volume list from the last refresh,
# then vol-delete and vol-list do not find a disk that is there.
pool_refresh() {
    pool_active || "${VIRSH[@]}" pool-start "$POOL" >/dev/null || die "cannot start pool $POOL"
    "${VIRSH[@]}" pool-refresh "$POOL" >/dev/null || die "cannot refresh pool $POOL"
}

vm_exists() { "${VIRSH[@]}" dominfo "$1" >/dev/null 2>&1; }

# A disk volume of VM with no VM defined. virt-install then makes VM-2.qcow2 and the old disk stays.
require_no_orphan_disk() {
    local vm="$1" v
    pool_refresh
    v=$("${VIRSH[@]}" vol-list "$POOL" 2>/dev/null | awk -v re="^${vm}(-[0-9]+)?[.]qcow2$" '$1 ~ re { print $1 }')
    [ -z "$v" ] \
        || die "pool $POOL has disks of '$vm' with no VM: $(tr '\n' ' ' <<<"$v")." \
               "Check, then: virsh vol-delete NAME --pool $POOL"
}

json_get() { python3 -c 'import json,sys; print(json.loads(sys.stdin.read()).get(sys.argv[1], ""))' "$1"; }

# Never use `undefine --remove-all-storage`: it also deletes the attached ISOs.
# Deletes only the device=disk volumes. --tpm deletes the swtpm state of the VM.
destroy_vm() {
    local vm="$1"; shift
    vm_exists "$vm" || { log "no VM '$vm'"; return 0; }
    local disks answer d
    # From the XML, not from domblklist columns: the repo path has spaces.
    mapfile -t disks < <("${VIRSH[@]}" dumpxml --inactive "$vm" | python3 -c '
import sys, xml.etree.ElementTree as ET
for d in ET.fromstring(sys.stdin.read()).iter("disk"):
    s = d.find("source")
    if d.get("device") == "disk" and s is not None and s.get("file"):
        print(s.get("file"))')
    warn "This deletes VM '$vm', its snapshots, NVRAM, TPM state, and these disks:"
    for d in "${disks[@]}"; do warn "  $d"; done
    warn "You cannot undo this."
    if [ "${1:-}" = "--confirm" ]; then
        answer="${2:-}"
    elif ! read -r -p "Type the VM name to confirm: " answer; then
        die "no terminal for the confirmation: use --confirm $vm"
    fi
    # A pasted answer can bring a CR or spaces.
    answer="${answer//[$'\r\t ']/}"
    [ "$answer" = "$vm" ] || die "confirmation does not match ('$answer' is not '$vm'); nothing deleted"
    "${VIRSH[@]}" destroy "$vm" 2>/dev/null || true
    "${VIRSH[@]}" undefine "$vm" --nvram --tpm --managed-save --snapshots-metadata
    pool_refresh
    for d in "${disks[@]}"; do
        "${VIRSH[@]}" vol-delete "$d" || warn "$d is not in a libvirt pool. Delete it manually."
    done
    log "destroyed $vm"
}

snapshot_vm() {
    local vm="$1" name="$2"
    if "${VIRSH[@]}" snapshot-info "$vm" "$name" >/dev/null 2>&1; then
        die "snapshot $name exists. Delete it first: virsh snapshot-delete $vm $name"
    fi
    "${VIRSH[@]}" snapshot-create-as "$vm" "$name" --description "build.sh $(date -u +%FT%TZ)" --atomic
    log "snapshot $name of $vm created"
}

screenshot_vm() {
    local vm="$1" out="$2"
    mkdir -p "$(dirname "$out")"
    "${VIRSH[@]}" screenshot "$vm" --file "$STAGE/$vm.ppm" >/dev/null \
        || die "could not screenshot '$vm' (is it running?)"
    if command -v magick >/dev/null 2>&1; then
        magick "$STAGE/$vm.ppm" "$out" && rm -f "$STAGE/$vm.ppm"
    else
        out="$STAGE/$vm.ppm"
    fi
    log "console -> $out"
}

agent_ping() {
    "${VIRSH[@]}" qemu-agent-command "$1" '{"execute":"guest-ping"}' --timeout 5 >/dev/null 2>&1
}

# Prints the first os-variant that the local osinfo database knows. Older osinfo-db has no entry for new releases.
pick_os_variant() {
    local known v
    known=$(virt-install --osinfo list 2>/dev/null | tr -s ' ,' '\n')
    for v in "$@"; do
        grep -qx "$v" <<<"$known" && { printf '%s\n' "$v"; return; }
    done
    printf '%s\n' "${@: -1}"
}

# guest_run ROLE FILE [NAME=VALUE ...]: runs FILE (repo path) in the guest through guest-exec.sh.
# Each NAME=VALUE becomes a variable at the top of the script: bash NAME=... (client, dc with IDP=freeipa),
# PowerShell $NAME = '...' (dc with IDP=windows).
# The values are quoted for the guest shell, so the file itself needs no escapes.
guest_run() {
    local role="$1" file="$2" pre="" kv; shift 2
    for kv in "$@"; do
        case "$role:${IDP:-windows}" in
            dc:windows) pre+="\$${kv%%=*} = $(ps_str "${kv#*=}")"$'\n' ;;
            *)          pre+="${kv%%=*}=$(printf '%q' "${kv#*=}")"$'\n' ;;
        esac
    done
    ./guest-exec.sh "$role" "$pre$(cat "$HERE/$file")"
}
