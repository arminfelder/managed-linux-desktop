# Fact-finding only. Repomd and RPMs are checked against checksums from the same
# HTTPS host, not against GPG signatures. Do not use this as an install trust path.
import gzip
import hashlib
import importlib.util
import os
import re
import subprocess
import sys
import urllib.request
import xml.etree.ElementTree as ET

REPOS = [
    ("updates", "https://dl.fedoraproject.org/pub/fedora/linux/updates/45/Everything/x86_64/"),
    ("releases", "https://dl.fedoraproject.org/pub/fedora/linux/releases/45/Everything/x86_64/os/"),
]
NS = {"c": "http://linux.duke.edu/metadata/common", "r": "http://linux.duke.edu/metadata/repo",
      "p": "http://linux.duke.edu/metadata/rpm"}
CNS = "{http://linux.duke.edu/metadata/common}"
FNS = "{http://linux.duke.edu/metadata/filelists}"
RNS = "{http://linux.duke.edu/metadata/repo}"

# (key, regex on the full file path)
FILE_OWNERS = [
    ("ildap.so", r"/ldb/(modules/ldb/)?ildap\.so$"),
    ("pam_mount.so", r"/security/pam_mount\.so$"),
    ("cifs.upcall", r"^/usr/s?bin/cifs\.upcall$"),
    ("net", r"^/usr/bin/net$"),
    ("tpm2_ptool", r"^/usr/bin/tpm2_ptool$"),
    ("libtpm2_pkcs11.so", r"/libtpm2_pkcs11\.so(\.\d+)*$"),
    ("p11-kit-trust.so", r"^/usr/lib(64)?/pkcs11/p11-kit-trust\.so$"),
    ("linuxx64.efi.stub", r"/linuxx64\.efi\.stub$"),
    ("sbsign", r"^/usr/bin/sbsign$"),
    ("mokutil", r"^/usr/bin/mokutil$"),
    ("certutil", r"^/usr/bin/certutil$"),
    ("pkcs11-tool", r"^/usr/bin/pkcs11-tool$"),
    ("ldapsearch", r"^/usr/bin/ldapsearch$"),
    ("fido2-token", r"^/usr/bin/fido2-token$"),
    ("plymouth-set-default-theme", r"/plymouth-set-default-theme$"),
    ("plymouth-spinner-theme", r"^/usr/share/plymouth/themes/spinner/spinner\.plymouth$"),
    ("sddm", r"^/usr/bin/sddm$"),
    ("plasmalogin", r"^/usr/(s?bin|libexec)/plasmalogin$"),
    ("gdm", r"^/usr/s?bin/gdm$"),
    ("efibootmgr", r"^/usr/s?bin/efibootmgr$"),
    ("klist", r"^/usr/bin/klist$"),
    ("host", r"^/usr/bin/host$"),
    ("firefox-etc-policies", r"^/etc/firefox"),
    ("realm", r"^/usr/s?bin/realm$"),
    ("adcli", r"^/usr/s?bin/adcli$"),
    ("getcert", r"^/usr/bin/getcert$"),
    ("tpm2_pkcs11_store_tool", r"^/usr/bin/tpm2_ptool$"),
    ("samba-gpupdate", r"/samba-gpupdate$"),
    ("samba_dsdb.so", r"/samba/ldb/samba_dsdb\.so$"),
    ("gpclass.py", r"/samba/gp/gpclass\.py$"),
    ("gp_firefox_ext.py", r"/samba/gp/gp_firefox_ext\.py$"),
    ("ukify", r"/ukify$"),
    ("dracut", r"^/usr/bin/dracut$"),
    ("nss_sss.so", r"/libnss_sss\.so\.2$"),
    ("pam_sss.so", r"/security/pam_sss\.so$"),
    ("impacket", r"^/usr/lib/python3[.\d]*/site-packages/impacket/__init__\.py$"),
    ("tpm2-openssl-provider", r"/ossl-modules/tpm2\.so$"),
]
# (key, package name, regex on file path): file lists printed per package
PKG_LISTS = [
    ("firefox", r"policies|distribution|^/etc/"),
    ("kde-settings-plasmalogin", r"^/(etc|usr/lib)/"),
    ("kde-settings-sddm", r"^/(etc|usr/lib)/"),
    ("plasma-login-manager", r"."),
    ("kde-settings", r"(sddm|plasmalogin|presets|preset)"),
    ("dnf5-plugin-automatic", r"systemd|\.conf$|automatic"),
    ("qemu-guest-agent", r"."),
    ("authselect-libs", r"/authselect/default/sssd/"),
    ("sddm", r"\.conf|\.service|/etc/|pam"),
]
# (ubuntu package, Fedora candidates in order); a candidate counts when a package of that name exists
PKG_MAP = [
    ("sssd", ["sssd"]), ("sssd-tools", ["sssd-tools"]), ("sssd-ad", ["sssd-ad"]),
    ("libnss-sss", ["sssd-client"]), ("libpam-sss", ["sssd-client"]),
    ("realmd", ["realmd"]), ("adcli", ["adcli"]),
    ("samba-common-bin", ["samba-common-tools"]), ("krb5-user", ["krb5-workstation"]),
    ("libpam-mount", ["pam_mount"]), ("cifs-utils", ["cifs-utils"]), ("keyutils", ["keyutils"]),
    ("bind9-host", ["bind-utils"]), ("tpm2-tools", ["tpm2-tools"]),
    ("libfido2-1", ["libfido2"]), ("fido2-tools", ["fido2-tools", "libfido2"]),
    ("mokutil", ["mokutil"]), ("efibootmgr", ["efibootmgr"]), ("sbsigntool", ["sbsigntools"]),
    ("systemd-boot-efi", ["systemd-boot-unsigned", "systemd-ukify"]),
    ("tpm2-openssl", ["tpm2-openssl"]), ("python3-impacket", ["python3-impacket"]),
    ("ldap-utils", ["openldap-clients"]), ("libsasl2-modules-gssapi-mit", ["cyrus-sasl-gssapi"]),
    ("certmonger", ["certmonger"]), ("libtpm2-pkcs11-1", ["tpm2-pkcs11"]),
    ("libtpm2-pkcs11-tools", ["tpm2-pkcs11-tools", "tpm2-pkcs11"]),
    ("libnss3-tools", ["nss-tools"]), ("opensc", ["opensc"]), ("curl", ["curl"]),
    ("qemu-guest-agent", ["qemu-guest-agent"]), ("p11-kit-modules", ["p11-kit-trust", "p11-kit"]),
    ("python3-samba", ["python3-samba"]),
    ("samba-dsdb-modules", ["samba-ldb-ldap-modules"]),
    ("unattended-upgrades", ["dnf5-plugin-automatic"]),
    ("plymouth", ["plymouth"]), ("plymouth-set-default-theme", ["plymouth-scripts"]),
    ("plymouth-theme-spinner", ["plymouth-theme-spinner"]),
    ("authselect-profile-sssd", ["authselect-libs"]), ("sddm-theme-breeze", ["sddm-breeze", "plasma-workspace"]),
    ("dracut", ["dracut"]), ("ukify", ["systemd-ukify"]),
    ("ubuntu-desktop-minimal", ["@workstation-product-environment"]),
    ("kde-plasma-desktop", ["@kde-desktop-environment"]),
    ("gdm3", ["gdm"]), ("sddm", ["sddm"]),
    ("firefox", ["firefox"]), ("google-chrome-stable", []), ("snx-rs", []),
]
THIRD_PARTY = {"google-chrome-stable", "snx-rs"}
GROUPS = ["workstation-product-environment", "kde-desktop-environment"]


def ubuntu_packages(root):
    names = set()
    inlist = False
    with open(os.path.join(root, "client", "user-data.tmpl")) as f:
        for line in f:
            if re.match(r"^  packages:\s*$", line):
                inlist = True
            elif inlist:
                m = re.match(r"^    - (\S+)\s*$", line)
                if not m:
                    break
                if "@@" not in m.group(1):
                    names.add(m.group(1))
    for dp, _, fs in os.walk(os.path.join(root, "client", "mld")):
        for fn in fs:
            if not fn.endswith(".sh"):
                continue
            with open(os.path.join(dp, fn)) as f:
                text_ = f.read().replace("\\\n", " ")
            for m in re.finditer(r"^\s*pkg_install\s+([^\n;&|]+)", text_, re.M):
                for w in m.group(1).split():
                    if re.fullmatch(r"[a-z0-9][a-z0-9+.-]*", w):
                        names.add(w)
    return names


def fetch(url, dest):
    if not os.path.exists(dest):
        with urllib.request.urlopen(url, timeout=300) as r, open(dest, "wb") as f:
            while True:
                b = r.read(1 << 20)
                if not b:
                    break
                f.write(b)
    return dest


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


class Pipe:
    def __init__(self, cmd):
        self.p = subprocess.Popen(cmd, stdout=subprocess.PIPE)

    def read(self, n=-1):
        b = self.p.stdout.read(n)
        if not b:
            self.p.stdout.close()
            if self.p.wait() != 0:
                raise RuntimeError("%s failed" % self.p.args[0])
        return b


def opener(path):
    if path.endswith(".zst"):
        return Pipe(["zstd", "-dc", path])
    if path.endswith(".xz"):
        return Pipe(["xz", "-dc", path])
    if path.endswith(".gz"):
        return gzip.open(path)
    return open(path, "rb")


def repodata(work):
    out = {}
    for name, base in REPOS:
        d = os.path.join(work, name)
        os.makedirs(d)
        repomd = fetch(base + "repodata/repomd.xml", os.path.join(d, "repomd.xml"))
        root = ET.parse(repomd).getroot()
        files = {}
        for data in root.findall(RNS + "data"):
            t = data.get("type")
            if t in ("primary", "filelists", "group"):
                href = data.find(RNS + "location").get("href")
                want = data.find(RNS + "checksum").text
                p = os.path.join(d, t + "-" + os.path.basename(href))
                for attempt in range(3):
                    fetch(base + href, p)
                    if sha256(p) == want:
                        break
                    os.remove(p)
                else:
                    sys.exit("checksum mismatch: " + href)
                files[t] = p
        out[name] = (base, files)
    return out


def vercmp_key(s):
    return [(0, int(x)) if x.isdigit() else (-1, x) for x in re.findall(r"\d+|[A-Za-z]+", s)]


def newer(a, b):
    ka = [vercmp_key(a[0]), vercmp_key(a[1]), vercmp_key(a[2])]
    kb = [vercmp_key(b[0]), vercmp_key(b[1]), vercmp_key(b[2])]
    return ka > kb


def read_primary(repos):
    pkgs = {}
    for name, (base, files) in repos.items():
        for _, el in ET.iterparse(opener(files["primary"]), events=("end",)):
            if el.tag != CNS + "package":
                continue
            arch = el.find(CNS + "arch").text
            if arch in ("x86_64", "noarch"):
                n = el.find(CNS + "name").text
                v = el.find(CNS + "version")
                ev = (v.get("epoch", "0"), v.get("ver"), v.get("rel"))
                rec = dict(name=n, arch=arch, evr=ev, repo=name, base=base,
                           href=el.find(CNS + "location").get("href"),
                           pkgid=el.find(CNS + "checksum").text,
                           rank=0 if name == "updates" else 1)
                old = pkgs.get(n)
                if old is None or (rec["rank"], 0) < (old["rank"], 0) or (
                        rec["rank"] == old["rank"] and newer(ev, old["evr"])):
                    pkgs[n] = rec
            el.clear()
    return pkgs


def nevra(r):
    e, v, rel = r["evr"]
    return "%s-%s%s-%s.%s" % (r["name"], e + ":" if e != "0" else "", v, rel, r["arch"])


def read_filelists(repos, pkgs):
    chosen = {r["pkgid"]: r["name"] for r in pkgs.values()}
    owners = {k: [] for k, _ in FILE_OWNERS}
    lists = {k: [] for k, _ in PKG_LISTS}
    own_re = [(k, re.compile(rx)) for k, rx in FILE_OWNERS]
    lst_re = {k: re.compile(rx) for k, rx in PKG_LISTS}
    for name, (base, files) in repos.items():
        for _, el in ET.iterparse(opener(files["filelists"]), events=("end",)):
            if el.tag != FNS + "package":
                continue
            pid = el.get("pkgid")
            n = chosen.get(pid)
            if n:
                for f in el.findall(FNS + "file"):
                    path = f.text
                    for k, rx in own_re:
                        if rx.search(path):
                            owners[k].append((n, path))
                    if n in lst_re and lst_re[n].search(path):
                        lists[n].append(path)
            el.clear()
    return owners, lists


def read_comps(repos):
    groups = {}
    for name in ("updates", "releases"):
        root = ET.parse(opener(repos[name][1]["group"])).getroot()
        for el in list(root.findall("group")) + list(root.findall("environment")):
            gid = el.find("id").text
            if gid not in groups:
                pk = [(x.get("type"), x.text) for x in el.iter("packagereq")]
                gl = [x.text for x in el.iter("groupid")]
                groups[gid] = (pk, gl)
    return groups


def closure(groups, gid, seen=None):
    seen = seen if seen is not None else {}
    if gid in seen or gid not in groups:
        return seen
    seen[gid] = groups[gid][0]
    for g in groups[gid][1]:
        closure(groups, g, seen)
    return seen


def cpio_files(data, want):
    out = {}
    pos = 0
    while pos + 110 <= len(data):
        if data[pos:pos + 6] != b"070701":
            raise ValueError("bad cpio magic")
        f = [int(data[pos + 6 + 8 * i:pos + 14 + 8 * i], 16) for i in range(13)]
        mode, size, nsize = f[1], f[6], f[11]
        name = data[pos + 110:pos + 110 + nsize - 1].decode()
        pos = (pos + 110 + nsize + 3) & ~3
        body = data[pos:pos + size]
        pos = (pos + size + 3) & ~3
        if name == "TRAILER!!!":
            break
        path = "/" + name.lstrip("./")
        if want(path):
            out[path] = ("LINK:" + body.decode()) if (mode & 0o170000) == 0o120000 else body
    return out


def rpm_payload(raw):
    def hdr(off):
        if raw[off:off + 3] != b"\x8e\xad\xe8":
            raise ValueError("bad rpm header")
        n = int.from_bytes(raw[off + 8:off + 12], "big")
        s = int.from_bytes(raw[off + 12:off + 16], "big")
        return off + 16 + 16 * n + s
    if raw[:4] != b"\xed\xab\xee\xdb":
        raise ValueError("not an rpm")
    off = hdr(96)
    off = (off + 7) & ~7
    off = hdr(off)
    return raw[off:]


def decompress(payload):
    if payload[:4] == b"\x28\xb5\x2f\xfd":
        cmd = ["zstd", "-dc"]
    elif payload[:4] == b"\xfd7zX":
        cmd = ["xz", "-dc"]
    elif payload[:2] == b"\x1f\x8b":
        return gzip.decompress(payload)
    else:
        raise ValueError("unknown payload compression")
    return subprocess.run(cmd, input=payload, stdout=subprocess.PIPE, check=True).stdout


def extract(work, rec, want):
    dest = os.path.join(work, "rpm-" + os.path.basename(rec["href"]))
    fetch(rec["base"] + rec["href"], dest)
    if sha256(dest) != rec["pkgid"]:
        sys.exit("rpm checksum mismatch: " + rec["href"])
    with open(dest, "rb") as f:
        raw = f.read()
    return cpio_files(decompress(rpm_payload(raw)), want)


def text(b):
    return b if isinstance(b, str) else b.decode("utf-8", "replace")


def active(t):
    return [l.strip() for l in t.splitlines() if l.strip() and not l.lstrip().startswith("#")]


def main():
    work, fixdir = sys.argv[1], sys.argv[2]
    problems = []
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    derived = ubuntu_packages(root)
    mapped = {u for u, _ in PKG_MAP}
    for u in sorted(derived - mapped):
        problems.append("Ubuntu package without PKG_MAP entry: " + u)
    if not derived:
        problems.append("no Ubuntu packages derived")
    repos = repodata(work)
    pkgs = read_primary(repos)
    owners, lists = read_filelists(repos, pkgs)
    comps = read_comps(repos)
    units = {}
    kv = []

    def put(k, v):
        kv.append("%s=%s" % (k, v))

    put("FEDORA_REPOS", ",".join(b for _, (b, _) in repos.items()))
    qg = pkgs["qemu-guest-agent"]
    put("QEMU_GA_PKG", nevra(qg))
    f = extract(work, qg, lambda p: p == "/etc/sysconfig/qemu-ga" or (
        p.startswith("/usr/lib/systemd/system/") and "qemu-guest-agent" in p))
    for p in sorted(f):
        for l in active(text(f[p])):
            put("QEMU_GA_LINE[%s]" % p, l)
    flt = [l for l in active(text(f.get("/etc/sysconfig/qemu-ga", b"")))
           if re.match(r"(BLACKLIST_RPC|FILTER_RPC|QEMU_GA_ARGS)", l)]
    put("QEMU_GA_FILTER", ";".join(flt) or "none")
    put("QEMU_GA_SYSCONFIG_PRESENT", "yes" if "/etc/sysconfig/qemu-ga" in f else "no")

    for gid in GROUPS:
        cl = closure(comps, gid)
        put("GROUP[%s]_SUBGROUPS" % gid, ",".join(sorted(cl)))
    dm_re = re.compile(r"sddm|plasma-login|plasmalogin|^gdm$|kde-settings")
    found = {}
    for gid in GROUPS:
        for g, pk in closure(comps, gid).items():
            for t, n in pk:
                if dm_re.search(n):
                    found.setdefault(gid, []).append("%s:%s(%s)" % (n, t, g))
    for gid in GROUPS:
        put("GROUP[%s]_DM_PACKAGES" % gid, ",".join(found.get(gid, [])))
    for g in ("kde-desktop", "gnome-desktop", "guest-desktop-agents", "domain-client", "workstation-product"):
        if g in comps:
            put("GROUP[%s]_PACKAGES" % g, ",".join("%s:%s" % t for t in comps[g][0]))
    kde_dm = " ".join(found.get("kde-desktop-environment", []))
    has_sddm = bool(re.search(r"(^| )sddm:", kde_dm))
    has_pl = "plasma-login-manager" in kde_dm
    dm = "sddm" if has_sddm and not has_pl else "plasmalogin" if has_pl and not has_sddm else "UNDECIDED"
    put("KDE_DM", dm)
    put("PKG_EXISTS[sddm]", nevra(pkgs["sddm"]) if "sddm" in pkgs else "no")
    put("PKG_EXISTS[plasma-login-manager]", nevra(pkgs["plasma-login-manager"]) if "plasma-login-manager" in pkgs else "no")
    put("DM_PACKAGES_IN_REPO", ",".join(sorted(n for n in pkgs if re.search(r"sddm|plasma-login|plasmalogin", n))))
    for k in ("sddm", "plasma-login-manager", "kde-settings-sddm", "kde-settings-plasmalogin", "kde-settings"):
        for p in lists.get(k, []):
            put("PKGFILE[%s]" % k, p)
            if p.endswith(".service") and "/systemd/system/" in p:
                units[k] = os.path.basename(p)
    put("KDE_DM_UNIT", units.get("sddm" if dm == "sddm" else "plasma-login-manager", "?"))
    for k in ("plasma-login-manager", "kde-settings-plasmalogin", "kde-settings-sddm"):
        if k not in pkgs:
            continue
        put("PKG[%s]" % k, nevra(pkgs[k]))
        f = extract(work, pkgs[k], lambda p: re.search(r"^/(etc|usr/lib)/(plasmalogin|sddm|sysconfig|pam\.d)|plasmalogin.*\.conf|sddm.*\.conf|/pam\.d/", p) and not p.endswith(".service"))
        for p in sorted(f):
            if isinstance(f[p], bytes):
                for l in (text(f[p]).splitlines() if p.endswith("plasmalogin.conf") else active(text(f[p]))):
                    put("CONF[%s:%s]" % (k, p), l)
            else:
                put("CONF[%s:%s]" % (k, p), f[p])
    rx = re.compile(rb"(?:Maximum|Minimum)Uid|HideUsers|HideShells|ShowUsers|UserList|UserModel|userList|showUserList|hideUser")
    for k in ("plasma-login-manager", "kcm-plasmalogin"):
        if k not in pkgs:
            continue
        f = extract(work, pkgs[k], lambda p: p.startswith(("/usr/bin/", "/usr/libexec/", "/usr/lib64/", "/usr/share/plasma", "/usr/share/plasmalogin", "/usr/share/kpackage", "/usr/share/kconf_update")))
        for p, b in sorted(f.items()):
            if isinstance(b, bytes):
                keys = sorted({m.decode() for m in rx.findall(b)})
                if keys:
                    put("PLASMALOGIN_USERLIST_KEYS[%s:%s]" % (k, p), ",".join(keys))
        put("PLASMALOGIN_SCANNED_FILES[%s]" % k, str(len(f)))

    for k in ("ildap.so",):
        o = sorted(set(owners[k]))
        put("ILDAP_FILES", ",".join("%s:%s" % t for t in o))
        put("ILDAP_PKG", ",".join(sorted({n for n, _ in o})) or "MISSING")

    for p in lists["firefox"]:
        put("FIREFOX_FILE", p)
    put("FIREFOX_POLICY_DIR", "/usr/lib64/firefox/distribution" if "/usr/lib64/firefox/distribution" in lists["firefox"] else "MISSING")
    put("FIREFOX_ETC_FILES", ",".join(p for p in lists["firefox"] if p.startswith("/etc/")) or "none")
    put("FIREFOX_PKG", nevra(pkgs["firefox"]))

    da = pkgs["dnf5-plugin-automatic"]
    put("DNF_AUTOMATIC_PKG", nevra(da))
    for p in lists["dnf5-plugin-automatic"]:
        put("DNF_AUTOMATIC_FILE", p)
    put("DNF_AUTOMATIC_UNITS", ",".join(sorted(os.path.basename(p) for p in lists["dnf5-plugin-automatic"]
                                              if p.endswith((".timer", ".service")))))
    put("DNF_AUTOMATIC_CONFIGS", ",".join(sorted(p for p in lists["dnf5-plugin-automatic"] if p.endswith(".conf"))))
    f = extract(work, da, lambda p: p.endswith((".timer", ".service", ".conf")) and "automatic" in p)
    for p in sorted(f):
        for l in active(text(f[p])):
            put("DNF_AUTOMATIC_LINE[%s]" % p, l)

    au = pkgs["authselect-libs"]
    put("AUTHSELECT_PKG", nevra(au))
    f = extract(work, au, lambda p: p.startswith("/usr/share/authselect/default/sssd/"))
    os.makedirs(fixdir, exist_ok=True)
    for src, dst in (("system-auth", "authselect-system-auth"), ("password-auth", "authselect-password-auth")):
        key = "/usr/share/authselect/default/sssd/" + src
        if key not in f or isinstance(f[key], str):
            sys.exit("authselect sssd profile lacks %s; have %s" % (src, sorted(f)))
        with open(os.path.join(fixdir, dst), "wb") as o:
            o.write(f[key])
        put("AUTHSELECT_FIXTURE", "%s (%s)" % (dst, hashlib.sha256(f[key]).hexdigest()[:16]))
    for p in sorted(f):
        put("AUTHSELECT_FILE", p)

    # Only the names that exist go into the fixture: the render test fedora_pkg_names fails on the others.
    spec = importlib.util.spec_from_file_location("fedora_pkgs", os.path.join(root, "tests", "fedora-pkgs.py"))
    fp = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(fp)
    used = {n for n, _ in fp.ks_packages(os.path.join(root, "client", "ks.cfg.tmpl"))}
    used |= {n for n, _ in fp.shell_packages(root)[0]}
    with open(os.path.join(fixdir, "fedora-pkgs.txt"), "w") as o:
        o.write("# Fedora 45 packages (releases + updates, x86_64 or noarch) that the client installs.\n"
                "# Made by tests/fedora-probe.sh from the repository metadata. Used by the render test fedora_pkg_names.\n")
        for n in sorted(used):
            if n in pkgs:
                o.write("%s\t%s\n" % (n, nevra(pkgs[n])))
            elif n not in fp.THIRD_PARTY:
                problems.append("package not in Fedora 45: " + n)

    print("\n".join(kv))
    print("--- OWNERS (key<TAB>package<TAB>NEVRA<TAB>path)")
    for k, _ in FILE_OWNERS:
        o = sorted(set(owners[k]))
        if not o:
            print("%s\tMISSING\t\t" % k)
            problems.append("no owner for file " + k)
        for n, p in o:
            print("%s\t%s\t%s\t%s" % (k, n, nevra(pkgs[n]), p))
    print("--- MAP (ubuntu_pkg<TAB>fedora_pkg<TAB>NEVRA)")
    for ub, cands in PKG_MAP:
        hit = None
        if not cands:
            print("%s\tNOT-IN-FEDORA\t" % ub)
            if ub not in THIRD_PARTY:
                problems.append("empty candidates for " + ub)
            continue
        for c in cands:
            if c.startswith("@"):
                if c[1:] in comps:
                    hit = (c, "group")
                    break
            elif c in pkgs:
                hit = (c, nevra(pkgs[c]))
                break
        print("%s\t%s\t%s" % (ub, hit[0] if hit else "MISSING", hit[1] if hit else ""))
        if not hit:
            problems.append("no Fedora package for " + ub)
    if dm == "UNDECIDED":
        problems.append("KDE_DM UNDECIDED")
    if kv and "ILDAP_PKG=MISSING" in kv:
        problems.append("ildap module has no package")
    for pr in problems:
        print("PROBLEM: " + pr, file=sys.stderr)
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
