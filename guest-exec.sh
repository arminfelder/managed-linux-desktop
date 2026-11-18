#!/usr/bin/env bash
# Run a snippet inside a lab VM through the QEMU guest agent.
#
#   ./guest-exec.sh dc 'Get-Date'                 PowerShell on the DC, as SYSTEM (IDP=freeipa: bash, as root)
#   ./guest-exec.sh client 'uname -a'             bash on the client, as root
#   ./guest-exec.sh client < script.sh
#   GUEST_EXEC_TIMEOUT=30 ./guest-exec.sh dc 'Get-Date'
#
# The agent needs no logon and no inbound firewall port.
# The exit code is the exit code of the snippet.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# lab.env, or .env until build.sh renames it.
env_file="$HERE/lab.env"; [ -f "$env_file" ] || env_file="$HERE/.env"
set -a
# shellcheck source=/dev/null
. "$env_file"
set +a
VIRSH=(virsh -c "$LIBVIRT_URI")
timeout_s="${GUEST_EXEC_TIMEOUT:-480}"

role="${1:?usage: guest-exec.sh dc|client [snippet]}"
shift
script="${1:-$(cat)}"

case "$role" in
    dc)     vm="$DC_VM" ;;
    client) vm="$CLIENT_VM" ;;
    *)      echo "unknown role '$role' (dc or client)" >&2; exit 2 ;;
esac

# JSON is built in Python, so no quoting passes between bash, JSON and the guest shell.
req=$(python3 - "$role" "$script" "${CLIENT_DISTRO:-ubuntu}" "${IDP:-windows}" <<'PY'
import base64, json, sys
role, script, distro, idp = sys.argv[1:5]
# The FreeIPA server is Fedora: bash through the SELinux wrapper, as on a Fedora client.
if role == "dc" and idp == "freeipa":
    role, distro = "client", "fedora"
if role == "dc":
    # Progress records come out as CLIXML on stderr and hide the real output.
    script = "$ProgressPreference='SilentlyContinue'\n" + script
    b64 = base64.b64encode(script.encode("utf-16-le")).decode()
    args = {"path": "powershell.exe",
            "arg": ["-NoProfile", "-ExecutionPolicy", "Bypass", "-EncodedCommand", b64]}
else:
    # Fedora: qemu-ga runs in virt_qemu_ga_t. Only this wrapper (client/mld/selinux/qemu-ga-run.sh) runs unconfined.
    args = {"path": "/usr/libexec/mld/qemu-ga-run" if distro == "fedora" else "/bin/bash", "arg": ["-s"],
            "input-data": base64.b64encode(script.encode()).decode()}
args["capture-output"] = True
print(json.dumps({"execute": "guest-exec", "arguments": args}))
PY
)

# virsh prints its own error (VM off, agent not connected). Stop there, not in the JSON parser.
started=$("${VIRSH[@]}" qemu-agent-command "$vm" "$req") || exit 1
pid=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["return"]["pid"])' <<<"$started")

end=$(( $(date +%s) + timeout_s ))
while [ "$(date +%s)" -lt "$end" ]; do
    out=$("${VIRSH[@]}" qemu-agent-command "$vm" \
          "{\"execute\":\"guest-exec-status\",\"arguments\":{\"pid\":$pid}}")
    if printf '%s' "$out" |
        python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin)["return"]["exited"] else 1)'; then
        printf '%s' "$out" | python3 -c '
import json,sys,base64
r = json.load(sys.stdin)["return"]
sys.stdout.write(base64.b64decode(r.get("out-data", "")).decode("utf-8", "replace"))
sys.stderr.write(base64.b64decode(r.get("err-data", "")).decode("utf-8", "replace"))
sys.exit(r.get("exitcode", 0))
'
        exit $?
    fi
    sleep 2
done
echo "guest-exec timed out after ${timeout_s}s" >&2
exit 1
