# Sourced by build.sh before lab.env is loaded: asks for the settings that lab.env does not have, then writes lab.env.
# env.example is the list: names, defaults, and the comment lines above each name as help text.
# "Missing" = not set, CHANGE-ME, or empty while a condition below needs a value.
# shellcheck shell=bash
# No helpers from common.sh here: common.sh needs LIBVIRT_URI from lab.env when it is sourced.

SETTINGS_EXAMPLE="$HERE/env.example"
SETTINGS_FILE="$HERE/lab.env"

declare -a S_NAMES=()
declare -A S_DEFAULT=() S_HELP=() S_SECTION=() S_SOURCE=()

# Allowed values. A setting not in this list takes any value.
declare -A S_CHOICES=(
    [UKI]="0 1" [UKI_TRUST]="db mok" [ENROLL_TPM2]="0 1" [CIFS_HOME]="0 1" [SMB_ENCRYPT]="0 1" [SNX_RS]="0 1"
    [CLIENT_DE]="gnome kde" [CLIENT_DISTRO]="ubuntu fedora"
    [PKI_ENROLL]="web dcom ipa none" [IDP]="windows freeipa" [NFS_HOME]="0 1" [O365_APPS]="0 1"
)
# The setting is asked only when the condition is true. Else the default is taken (empty for a password).
# shellcheck disable=SC2016 # The conditions are evaluated later (eval), when the earlier answers are set.
declare -A S_WHEN=(
    [UKI_TRUST]='[ "${UKI:-0}" = 1 ]'
    [UBUNTU_ISO]='[ "${CLIENT_DISTRO:-ubuntu}" != fedora ]'
    [UBUNTU_URL]='[ "${CLIENT_DISTRO:-ubuntu}" != fedora ]'
    [FEDORA_ISO]='[ "${CLIENT_DISTRO:-ubuntu}" = fedora ] || [ "${IDP:-windows}" = freeipa ]'
    [FEDORA_URL]='[ "${CLIENT_DISTRO:-ubuntu}" = fedora ] || [ "${IDP:-windows}" = freeipa ]'
    [FEDORA_SUMS_URL]='[ "${CLIENT_DISTRO:-ubuntu}" = fedora ] || [ "${IDP:-windows}" = freeipa ]'
    [WINSERVER_ISO]='[ "${IDP:-windows}" = windows ]'
    [WINSERVER_URL]='[ "${IDP:-windows}" = windows ]'
    [VIRTIO_ISO]='[ "${IDP:-windows}" = windows ]'
    [VIRTIO_URL]='[ "${IDP:-windows}" = windows ]'
    [WIN_IMAGE_INDEX]='[ "${IDP:-windows}" = windows ]'
    [AD_LEVEL]='[ "${IDP:-windows}" = windows ]'
    [NETBIOS]='[ "${IDP:-windows}" = windows ]'
    [REGISTERED_OWNER]='[ "${IDP:-windows}" = windows ]'
    [DSRM_PW]='[ "${IDP:-windows}" = windows ]'
    [JOIN_USER]='[ "${IDP:-windows}" = windows ]'
    [JOIN_PW]='[ "${IDP:-windows}" = windows ]'
    [CIFS_HOME]='[ "${IDP:-windows}" = windows ]'
    [SMB_ENCRYPT]='[ "${IDP:-windows}" = windows ]'
    [CA_NAME]='[ "${IDP:-windows}" = windows ]'
    [IPA_DM_PW]='[ "${IDP:-windows}" = freeipa ]'
    [NFS_HOME]='[ "${IDP:-windows}" = freeipa ]'
    [MOK_PASSWORD]='[ "${UKI:-0}" = 1 ] && [ "${UKI_TRUST:-db}" = mok ]'
    [TPM2_PCRS]='[ "${ENROLL_TPM2:-0}" = 1 ]'
    [FIDO2_PIN]='[ -n "${FIDO2_HOSTDEV:-}" ]'
    [MACHINE_TOKEN_PIN]='[ "${PKI_ENROLL:-web}" != none ]'
)

s_say()  { printf '\033[1;36m[config]\033[0m %s\n' "$*" >&2; }
s_die()  { printf '\033[1;31m[config]\033[0m %s\n' "$*" >&2; exit 1; }
s_secret() { [ "${S_DEFAULT[$1]}" = CHANGE-ME ]; }
# s_indent PREFIX TEXT: prints each line of TEXT with PREFIX.
s_indent() { local l; while IFS= read -r l; do printf '%s%s\n' "$1" "$l"; done <<<"$2"; }
s_masked() { if s_secret "$1" && [ -n "$2" ]; then echo '********'; else printf '%s' "$2"; fi; }

# Reads env.example into S_NAMES, S_DEFAULT (raw text after "="), S_HELP, S_SECTION.
settings_parse() {
    local line help="" section="" name
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            "# ---"*) section=$(sed -E 's/^# -+ *//; s/ *-+$//' <<<"$line"); help="" ;;
            "#"*) help+="${help:+$'\n'}${line#\# }" ;;
            [A-Z_]*=*)
                name=${line%%=*}
                S_NAMES+=("$name"); S_DEFAULT[$name]=${line#*=}; S_HELP[$name]=$help; S_SECTION[$name]=$section
                help="" ;;
            *) help="" ;;
        esac
    done < "$SETTINGS_EXAMPLE"
}

# A 14-character password with upper case, lower case and digits (Windows complexity: 3 of 4 classes).
settings_password() {
    local p
    while :; do
        p=$(openssl rand -base64 30 | tr -dc 'A-Za-z0-9' | cut -c1-14)
        [[ ${#p} -eq 14 && "$p" =~ [A-Z] && "$p" =~ [a-z] && "$p" =~ [0-9] ]] && { printf '%s' "$p"; return; }
    done
}

settings_missing() {
    local n="$1" when="${S_WHEN[$1]:-}"
    [ -n "${!n+x}" ] || return 0
    [ "${!n}" != CHANGE-ME ] || return 0
    [ -z "${!n}" ] && [ -n "$when" ] && s_secret "$n" && eval "$when"
}

# settings_ask NAME: prints the help, reads a value, sets $NAME. ANSWER = the line for lab.env.
settings_ask() {
    local n="$1" def="${S_DEFAULT[$1]}" choices="${S_CHOICES[$1]:-}" v v2 shown
    if [ -n "${S_SECTION[$n]}" ] && [ "${S_SECTION[$n]}" != "${S_LAST_SECTION:-}" ]; then
        printf '\n\033[1m%s\033[0m\n' "${S_SECTION[$n]}" >&2; S_LAST_SECTION=${S_SECTION[$n]}
    fi
    [ -z "${S_HELP[$n]}" ] || s_indent '  ' "${S_HELP[$n]}" >&2
    if s_secret "$n"; then
        while :; do
            read -rsp "  $n (Enter = generate): " v </dev/tty; printf '\n' >&2
            if [ -z "$v" ]; then v=$(settings_password); S_SOURCE[$n]=generated; break; fi
            read -rsp "  $n again: " v2 </dev/tty; printf '\n' >&2
            [ "$v" = "$v2" ] && { S_SOURCE[$n]=entered; break; }
            s_say "the two entries are not the same, again"
        done
        ANSWER="$n=$(printf '%q' "$v")"
    else
        while :; do
            read -rp "  $n${choices:+ (${choices// /|})} [$def]: " v </dev/tty
            if [ -z "$v" ]; then ANSWER="$n=$def"; S_SOURCE[$n]=default; break; fi
            if [ -z "$choices" ] || [[ " $choices " == *" $v "* ]]; then
                ANSWER="$n=$(printf '%q' "$v")"; S_SOURCE[$n]=entered; break
            fi
            s_say "$n must be one of: $choices"
        done
    fi
    eval "$ANSWER"
    shown=$(s_masked "$n" "${!n}")
    printf '  -> %s = %s (%s)\n' "$n" "$shown" "${S_SOURCE[$n]}" >&2
}

# settings_take NAME REASON: no prompt. Default for a normal setting, a generated or empty password.
settings_take() {
    local n="$1" why="$2"
    if s_secret "$n"; then
        if [ "$why" = "no terminal" ]; then
            ANSWER="$n=$(printf '%q' "$(settings_password)")"; S_SOURCE[$n]="generated, $why"
        else ANSWER="$n="; S_SOURCE[$n]="empty, $why"; fi
    else
        ANSWER="$n=${S_DEFAULT[$n]}"; S_SOURCE[$n]="default, $why"
    fi
    eval "$ANSWER"
}

# settings_merge < lab.env: replaces each line with a name in new[] of settings_write, and removes that name from new[].
settings_merge() {
    local line n
    while IFS= read -r line || [ -n "$line" ]; do
        n=${line%%=*}
        if [[ "$line" == [A-Z_]*=* && -n "${new[$n]+x}" ]]; then printf '%s\n' "${new[$n]}"; unset "new[$n]"
        else printf '%s\n' "$line"; fi
    done
}

# settings_append FILE: appends the names that are still in new[] of settings_write, with their help text.
settings_append() {
    local n
    [ "${#new[@]}" -gt 0 ] || return 0
    printf '\n# --- added by ./build.sh config, %s ---\n' "$(date -u +%F)" >> "$1"
    for n in "${S_NAMES[@]}"; do
        [ -n "${new[$n]+x}" ] || continue
        [ -z "${S_HELP[$n]}" ] || s_indent '# ' "${S_HELP[$n]}" >> "$1"
        printf '%s\n' "${new[$n]}" >> "$1"
    done
}

# settings_from_example < env.example: replaces each line with a name in new[] of settings_write.
settings_from_example() {
    local line n
    while IFS= read -r line || [ -n "$line" ]; do
        n=${line%%=*}
        if [[ "$line" == [A-Z_]*=* && -n "${new[$n]+x}" ]]; then printf '%s\n' "${new[$n]}"
        elif [[ "$line" == "# Copy to lab.env and edit."* ]]; then
            printf '# Written by ./build.sh config from env.example. Edit it, or run ./build.sh config again.\n'
        else printf '%s\n' "$line"; fi
    done
}

# settings_write NAME=LINE...: replaces the NAME= line in lab.env, or appends it.
# A missing lab.env comes from env.example.
settings_write() {
    local tmp line
    declare -A new=()
    for line in "$@"; do new[${line%%=*}]=$line; done
    tmp=$(mktemp "$SETTINGS_FILE.XXXXXX")
    if [ -f "$SETTINGS_FILE" ]; then
        settings_merge < "$SETTINGS_FILE" > "$tmp"
        settings_append "$tmp"
    else
        settings_from_example < "$SETTINGS_EXAMPLE" > "$tmp"
    fi
    chmod 600 "$tmp"
    mv "$tmp" "$SETTINGS_FILE"
}

# Asks for each missing setting (in env.example order), writes lab.env, and reports the values it took.
settings_complete() {
    settings_parse
    # shellcheck source=/dev/null
    if [ -f "$SETTINGS_FILE" ]; then set -a; . "$SETTINGS_FILE"; set +a; fi
    local n tty=1 answers=()
    local asked=()
    [ -r /dev/tty ] && { : </dev/tty; } 2>/dev/null || tty=0
    for n in "${S_NAMES[@]}"; do
        settings_missing "$n" || continue
        if [ -n "${S_WHEN[$n]:-}" ] && ! eval "${S_WHEN[$n]}"; then settings_take "$n" "not needed"
        elif [ "$tty" = 0 ]; then settings_take "$n" "no terminal"
        else
            [ "${#asked[@]}" -gt 0 ] \
                || s_say "$(basename "$SETTINGS_FILE") has no value for some settings. Enter = default in []."
            settings_ask "$n"
        fi
        asked+=("$n"); answers+=("$ANSWER")
    done
    [ "${#asked[@]}" -gt 0 ] || return 0
    settings_write "${answers[@]}"
    s_say "values taken, written to $SETTINGS_FILE:"
    for n in "${asked[@]}"; do printf '  %-16s %s (%s)\n' "$n" "$(s_masked "$n" "${!n}")" "${S_SOURCE[$n]}" >&2; done
}

# ./build.sh config: all settings with their values. Passwords are masked.
settings_show() {
    [ "${#S_NAMES[@]}" -gt 0 ] || settings_parse
    local n section=""
    for n in "${S_NAMES[@]}"; do
        if [ "${S_SECTION[$n]}" != "$section" ]; then
            section=${S_SECTION[$n]}; printf '\n\033[1m%s\033[0m\n' "${section:-general}"
        fi
        printf '  %-16s %s\n' "$n" "$(s_masked "$n" "${!n-}")"
    done
}
