# Sourced by firstboot.sh and by guest snippets. Every function returns 0 on a normal path (set -e, ERR trap).
# Clients built before CLIENT_DISTRO existed have no value in config.env: they are Ubuntu.
CLIENT_DISTRO="${CLIENT_DISTRO:-ubuntu}"

case "$CLIENT_DISTRO" in
ubuntu)
    SHIM_EFI='\EFI\ubuntu\shimx64.efi'
    SHIM_FILE=/boot/efi/EFI/ubuntu/shimx64.efi
    BOOT_LABEL_RE=ubuntu
    PKCS11_DIR=/usr/lib/x86_64-linux-gnu/pkcs11
    CA_ANCHOR_DIR=/usr/local/share/ca-certificates/mld
    CA_ANCHOR_PREFIX=
    ca_trust_update() { update-ca-certificates >/dev/null; }
    SSH_UNIT=ssh.service
    PAM_AUTH_FILES=/etc/pam.d/common-auth
    PAM_SESSION_FILES=/etc/pam.d/common-session
    pkg_installed() { dpkg -s "$1" >/dev/null 2>&1; }
    pkg_version() { dpkg-query -W -f='${Version}' "$1" 2>/dev/null || true; }
    pkg_refresh() { apt-get update; }
    _pkg_add() { DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"; }
    _pkg_del() { DEBIAN_FRONTEND=noninteractive apt-get purge -y "$@"; }
    initrd_path() { echo "/boot/initrd.img-$1"; }
    ;;
fedora)
    SHIM_EFI='\EFI\fedora\shimx64.efi'
    SHIM_FILE=/boot/efi/EFI/fedora/shimx64.efi
    BOOT_LABEL_RE=fedora
    PKCS11_DIR=/usr/lib64/pkcs11
    CA_ANCHOR_DIR=/etc/pki/ca-trust/source/anchors
    CA_ANCHOR_PREFIX=mld-
    ca_trust_update() { update-ca-trust extract; }
    SSH_UNIT=sshd.service
    PAM_AUTH_FILES="/etc/pam.d/system-auth /etc/pam.d/password-auth"
    PAM_SESSION_FILES="/etc/pam.d/system-auth /etc/pam.d/password-auth"
    pkg_installed() { rpm -q "$1" >/dev/null 2>&1; }
    pkg_version() { rpm -q --qf '%{VERSION}-%{RELEASE}' "$1" 2>/dev/null || true; }
    pkg_refresh() { dnf -q makecache; }
    _pkg_add() { dnf -y install "$@"; }
    _pkg_del() { dnf -y remove "$@"; }
    initrd_path() { echo "/boot/initramfs-$1.img"; }
    ;;
*)
    echo "distro.sh: CLIENT_DISTRO must be ubuntu or fedora, not '$CLIENT_DISTRO'" >&2
    return 1
    ;;
esac

# Installs the packages that are not installed yet, in one call.
pkg_install() {
    local p missing=()
    for p in "$@"; do pkg_installed "$p" || missing+=("$p"); done
    if [ "${#missing[@]}" -gt 0 ]; then _pkg_add "${missing[@]}"; fi
}

# Removes the packages that are installed, in one call.
pkg_purge() {
    local p present=()
    for p in "$@"; do ! pkg_installed "$p" || present+=("$p"); done
    if [ "${#present[@]}" -gt 0 ]; then _pkg_del "${present[@]}"; fi
}
