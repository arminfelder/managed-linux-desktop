# shellcheck shell=bash
# Runs in the client as root (build.sh guest_run). Prints KEY=VALUE lines about the current boot.
# systemd-stub sets StubInfo: the running kernel came from a UKI.
stub=/sys/firmware/efi/efivars/StubInfo-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f
mok=""
if [ -x /usr/local/sbin/mld-uki ] && [ -f /etc/mld/sb/db.crt ]; then mok=$(/usr/local/sbin/mld-uki mok-state 2>&1); fi
echo "mok=$mok"
echo "lab_in_db=$(mokutil --db 2>/dev/null | grep -c 'MLD lab UKI signing key')"
echo "uki_booted=$( [ -e "$stub" ] && echo yes || echo no)"
echo "boot_entry=$(efibootmgr 2>/dev/null | awk '
    /^BootCurrent:/ { c = $2 }
    $1 ~ ("^Boot" c) { sub(/^Boot[0-9A-F]+\*? /, ""); sub(/\t.*/, ""); print; exit }')"
echo "running=$(uname -r)"
# Same list as mld-uki kernels: the Fedora rescue kernel has no module directory and no UKI.
echo "kernels=$(for f in /boot/vmlinuz-*; do k=${f#/boot/vmlinuz-}; [ -e "$f" ] && [ -d "/lib/modules/$k" ] && echo "$k"; done | sort -V | tr '\n' ' ')"
echo "uki_files=$(ls /boot/efi/EFI/Linux/ 2>/dev/null | sed -n 's/^mld-\(.*\)\.efi$/\1/p' | sort -V | tr '\n' ' ')"
echo "uki_legacy=$(cd /boot/efi/EFI/Linux 2>/dev/null && ls mld.efi mld-prev.efi 2>/dev/null | tr '\n' ' ')"
echo "uki_entries=$(efibootmgr 2>/dev/null | awk -F '\t' '/^Boot[0-9A-F][0-9A-F][0-9A-F][0-9A-F]\*? MLD UKI/ { n = split($1, w, " "); print w[n] }' | sort -V | tr '\n' ' ')"
echo "boot_first=$(efibootmgr 2>/dev/null | awk -F '\t' '
    /^BootOrder:/ { split($0, o, /[ ,]/); f = o[2] }
    $1 ~ ("^Boot" f) && f != "" { sub(/^Boot[0-9A-F]+\*? /, "", $1); print $1; exit }')"
