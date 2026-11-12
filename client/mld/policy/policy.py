#!/usr/bin/python3
"""Pull the browser policy from the FreeIPA server (IDP=freeipa), as root.

Gets https://<server>/mld-policy/manifest with the host Kerberos key, then each file in it. Each file must match its
sha256 and be valid JSON. The server gives names only: this tool maps each name to a fixed path. A failed pull keeps
the files of the last good pull. Also writes the IPA CA certificates into the Chrome policy (Chrome on Linux does not
read the system store).

Usage:
    mld-policy            pull and install (mld-policy.service, every 90 min)
    mld-policy --check    print the installed files, change nothing
"""
import base64
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile

CONF = "/etc/mld/policy/policy.conf"
STATE = "/var/lib/mld/policy.installed"
IPA_CA = "/etc/ipa/ca.crt"
CHROME_DIR = "/etc/opt/chrome/policies/managed"
CHROME_CA = CHROME_DIR + "/mld-ca.json"
FIREFOX = "/etc/firefox/policies/policies.json"
CCACHE = "FILE:/run/mld-policy.ccache"


def conf():
    """KEY=VALUE lines of policy.conf (written by phase_policy)."""
    out = {}
    with open(CONF) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                out[k] = v
    return out


def target(name):
    """Fixed path for a manifest name. None: the name is not known, the file is not used."""
    m = re.fullmatch(r"chrome-([a-z0-9-]+)\.json", name)
    if m:
        return f"{CHROME_DIR}/mld-policy-{m.group(1)}.json"
    if name == "firefox.json":
        return FIREFOX
    return None


def firefox_fix(data, p11kit):
    """Firefox: the p11-kit-trust path is per distro. Empty = Fedora, where Firefox reads the system store already."""
    add = data.get("policies", {}).get("SecurityDevices", {}).get("Add", {})
    if "p11-kit-trust" in add:
        if p11kit:
            add["p11-kit-trust"] = p11kit
        else:
            del add["p11-kit-trust"]
            if not add:
                del data["policies"]["SecurityDevices"]
    return data


def write(path, text):
    """Atomic replace. Returns True when the content changed."""
    try:
        with open(path) as f:
            if f.read() == text:
                return False
    except FileNotFoundError:
        pass
    os.makedirs(os.path.dirname(path), mode=0o755, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".mld-policy.")
    with os.fdopen(fd, "w") as f:
        f.write(text)
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)
    return True


def chrome_ca():
    """All certificates of /etc/ipa/ca.crt (ipa-certupdate keeps it current) as Chrome CACertificates."""
    with open(IPA_CA) as f:
        pem = f.read()
    ders = [base64.b64encode(base64.b64decode("".join(b.split()))).decode()
            for b in re.findall(r"-----BEGIN CERTIFICATE-----(.*?)-----END CERTIFICATE-----", pem, re.S)]
    if not ders:
        sys.exit(f"mld-policy: no certificate in {IPA_CA}")
    if write(CHROME_CA, json.dumps({"CACertificates": ders}, indent=2) + "\n"):
        print(f"updated: {CHROME_CA} ({len(ders)} CA)")


def fetch(url, out):
    env = dict(os.environ, KRB5CCNAME=CCACHE)
    r = subprocess.run(["curl", "-sS", "--fail", "--negotiate", "-u", ":", "--cacert", IPA_CA, "-o", out, url],
                       env=env, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"mld-policy: {url}: {r.stderr.strip()} (curl {r.returncode})")


def pull(c):
    # Host ticket from /etc/krb5.keytab (ipa-client-install), in a private cache.
    r = subprocess.run(["kinit", "-k", "-c", CCACHE, f"host/{c['HOST_FQDN']}"], capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"mld-policy: kinit -k host/{c['HOST_FQDN']}: {r.stderr.strip()}")
    base = f"https://{c['DC_FQDN']}/mld-policy"
    with tempfile.TemporaryDirectory() as tmp:
        fetch(f"{base}/manifest", f"{tmp}/manifest")
        files = {}
        with open(f"{tmp}/manifest") as f:
            for line in f:
                if not line.strip():
                    continue
                digest, name = line.split()
                path = target(name)
                if path is None:
                    print(f"mld-policy: {name}: unknown name, not used", file=sys.stderr)
                    continue
                fetch(f"{base}/{name}", f"{tmp}/{name}")
                with open(f"{tmp}/{name}", "rb") as g:
                    raw = g.read()
                if hashlib.sha256(raw).hexdigest() != digest:
                    sys.exit(f"mld-policy: {name}: sha256 does not match the manifest")
                data = json.loads(raw)
                if path == FIREFOX:
                    data = firefox_fix(data, c.get("P11KIT_TRUST", ""))
                files[path] = json.dumps(data, indent=2) + "\n"
    # All files are good: install them, then remove the files of the last pull that the manifest no longer has.
    for path, text in files.items():
        if write(path, text):
            print(f"updated: {path}")
    try:
        with open(STATE) as f:
            old = set(f.read().split())
    except FileNotFoundError:
        old = set()
    for path in sorted(old - set(files)):
        if os.path.exists(path):
            os.remove(path)
            print(f"removed: {path}")
    write(STATE, "".join(p + "\n" for p in sorted(files)))
    subprocess.run(["kdestroy", "-c", CCACHE], capture_output=True)


def check():
    try:
        with open(STATE) as f:
            paths = f.read().split()
    except FileNotFoundError:
        sys.exit("mld-policy: no pull yet")
    for p in paths + [CHROME_CA]:
        print(f"{p}: {'present' if os.path.exists(p) else 'MISSING'}")


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--check":
        check()
        return
    if os.geteuid() != 0:
        sys.exit("mld-policy: run as root")
    chrome_ca()
    pull(conf())


if __name__ == "__main__":
    main()
