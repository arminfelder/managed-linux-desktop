# SELinux stays enforcing. Fixes go through booleans, file contexts and the small module mld.
# Sourced by firstboot.sh on Fedora. Needs $CFG, $STATE, phase, fail.

selinux_lines() { awk '!/^[[:space:]]*(#|$)/' "$1"; }

selinux_restore() {
    local re path
    while read -r re _; do
        path=$(printf '%s' "$re" | sed 's/[][(){}.*+?^$|\\].*//')
        while [ ! -e "$path" ] && [ "$(printf '%s' "$path" | tr -cd / | wc -c)" -gt 2 ]; do path=$(dirname "$path"); done
        [ -e "$path" ] || { echo "restorecon: $path does not exist, skipped"; continue; }
        restorecon -R "$path"
    done < <(selinux_lines "$CFG/selinux/fcontexts.list")
}

phase_selinux_restore() {
    phase selinux_restore
    selinux_restore
}

phase_selinux() {
    phase selinux
    [ "$(getenforce)" = Enforcing ] || fail "SELinux is not enforcing"
    local name val re type sha
    while read -r name val; do
        setsebool -P "$name" "$val"
    done < <(selinux_lines "$CFG/selinux/booleans.list")
    while read -r re type; do
        if semanage fcontext -l -C | awk -v r="$re" '$1 == r { f = 1 } END { exit !f }'; then
            semanage fcontext -m -t "$type" "$re"
        else
            semanage fcontext -a -t "$type" "$re"
        fi
    done < <(selinux_lines "$CFG/selinux/fcontexts.list")
    sha=$(sha256sum "$CFG/selinux/mld.te")
    if [ "$sha" != "$(cat "$STATE/selinux.sha" 2>/dev/null || true)" ]; then
        local w; w=$(mktemp -d)
        checkmodule -M -m -o "$w/mld.mod" "$CFG/selinux/mld.te"
        semodule_package -o "$w/mld.pp" -m "$w/mld.mod"
        semodule -i "$w/mld.pp"
        rm -rf "$w"
        printf '%s\n' "$sha" > "$STATE/selinux.sha"
    fi
    selinux_restore
}
