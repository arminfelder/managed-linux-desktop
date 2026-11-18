#!/usr/bin/python3
"""Certificate autoenrollment with keys in the TPM: from AD as the Windows client does it, or from FreeIPA.

  mld-autoenroll setup machine   TPM token (tpm2-pkcs11), NSS database, certmonger CA (as root)
  mld-autoenroll machine         track every template the computer may autoenroll (as root)
  mld-autoenroll setup user      the same for the logged-in AD user (session certmonger, ~/.pki/nssdb)
  mld-autoenroll user            track every template the user may autoenroll (Kerberos ticket of the login)
  mld-autoenroll status [user]   certmonger requests of this tool
  mld-autoenroll prune [user]    keep only the newest certificate per key in the TPM token (certmonger post-save)

A template qualifies when the CA publishes it, it is schema version 2 or higher, it has the autoenrollment
flag, it is a machine (or user) template, and its ACL gives Enroll and Autoenroll to the account or its groups.
certmonger then makes the key in the TPM token, submits through mld-cm-submit and renews before expiry.

IDP=freeipa (/etc/mld-cert.conf): one machine certificate from the IPA CA (certmonger CA "IPA" of
ipa-client-install, host keytab) and one user certificate (profile mldUserCert, session CA with ipa-submit and the
login ticket). The CA ACLs on the server decide who gets a certificate.
"""
import base64
import os
import pwd
import secrets
import sqlite3
import subprocess
import sys
import time

GUID_ENROLL = "0e10c968-78fb-11d2-90d4-00c04f79dc55"
GUID_AUTOENROLL = "a05b8cc2-17bc-4802-a710-e7c15ab866a2"
RIGHT_NAMES = {GUID_ENROLL: "enroll", GUID_AUTOENROLL: "autoenroll"}
# Everyone, Authenticated Users: in the token of every domain principal, but not in tokenGroups.
WELL_KNOWN = {"S-1-1-0", "S-1-5-11"}
CT_FLAG_MACHINE_TYPE = 0x40
CT_FLAG_AUTO_ENROLLMENT = 0x20
# LDAP_SERVER_SD_FLAGS_OID with OWNER|GROUP|DACL: without it, a non-admin gets no nTSecurityDescriptor.
SD_FLAGS = "!1.2.840.113556.1.4.801=::MAMCAQc="

# TPM-bound files of a user stay on this device: the home can roam (CIFS), the TPM does not.
# A key blob from another device fails in Esys_Load with TPM_RC_INTEGRITY (0x1df).
USER_STATE_ROOT = "/var/lib/mld-users"


def user_state():
    """/var/lib/mld-users/<uid>, mode 700, owned by the user. The parent has mode 1733 (firstboot)."""
    uid = os.getuid()
    d = f"{USER_STATE_ROOT}/{uid}"
    os.makedirs(d, mode=0o700, exist_ok=True)
    st = os.stat(d)
    if st.st_uid != uid or (st.st_mode & 0o777) != 0o700:
        sys.exit(f"mld-autoenroll: {d} must be owned by uid {uid} with mode 700")
    return d


def link_to_device(home, name, target):
    """~/NAME -> TARGET on this device. The home roams (CIFS): certmonger and its helpers find the token
    store and their state only through $HOME, and the TPM keys work only on this device."""
    link = os.path.join(home, name)
    os.makedirs(target, mode=0o700, exist_ok=True)
    if os.path.islink(link):
        if os.readlink(link) == target:
            return False
        os.remove(link)
    elif os.path.exists(link):
        # From an older device or from the time before this change. Kept, not deleted.
        old = f"{link}.roamed-{time.strftime('%Y%m%d%H%M%S')}"
        os.rename(link, old)
        print(f"{link} moved to {old}")
    os.makedirs(os.path.dirname(link), exist_ok=True)
    try:
        os.symlink(target, link)
    except OSError as e:
        sys.exit(f"mld-autoenroll: cannot make the link {link} ({e.strerror}). "
                 "The CIFS home needs the mount option mfsymlinks: log out and log in again")
    print(f"{link} -> {target}")
    return True


def user_profile():
    state = user_state()
    home = pwd.getpwuid(os.getuid()).pw_dir
    return {
        # tpm2-pkcs11 searches $HOME/.tpm2_pkcs11: setup makes it a link to this directory.
        "store": f"{state}/.tpm2_pkcs11",
        "home": home,
        "state": state,
        # Only the module registration: the certificate and the key are in the token, so the database can roam.
        "nssdb": f"sql:{home}/.pki/nssdb",
        "pin": f"{state}/token.pin",
        "token": "mld-user",
        "ca": "MLD-AD-user",
        "session": True,
    }


MACHINE = {
    # A default search path of tpm2-pkcs11. Stock certmonger does not pass TPM2_PKCS11_STORE to the
    # processes that load the module ("Could not find or create a pkcs11 store"), so no variable is needed.
    "store": "/etc/tpm2_pkcs11",
    "nssdb": "sql:/etc/mld/pki/nssdb",
    "pin": "/etc/mld/pki/token.pin",
    "token": "mld-machine",
    "ca": "MLD-AD-machine",
    "session": False,
}


def conf():
    c = {}
    with open("/etc/mld-cert.conf") as f:
        for line in f:
            if "=" in line:
                k, v = line.strip().split("=", 1)
                c[k] = v.strip("'\"")
    return c


def freeipa(c):
    return c.get("IDP", "windows") == "freeipa"


def ipa_default():
    """host and realm of this client: /etc/ipa/default.conf (ipa-client-install)."""
    out = {}
    with open("/etc/ipa/default.conf") as f:
        for line in f:
            if "=" in line:
                k, v = line.split("=", 1)
                out[k.strip()] = v.strip()
    return out


# Fedora, Ubuntu.
IPA_SUBMIT = ["/usr/libexec/certmonger/ipa-submit", "/usr/lib/certmonger/ipa-submit"]


def profile(who):
    """MACHINE or the user profile. IDP=freeipa: the stock CA IPA for the machine, a session CA for the user."""
    p = dict(MACHINE) if who == "machine" else user_profile()
    if freeipa(conf()):
        p["ca"] = "IPA" if who == "machine" else "mld-ipa-user"
    return p


SECRET_OPTS = {"--userpin", "--sopin", "-P"}


def shown(cmd):
    """The command for messages, with PIN values masked."""
    return " ".join("***" if i and cmd[i - 1] in SECRET_OPTS else a for i, a in enumerate(cmd))


def run(cmd, env=None, check=True, quiet=False):
    r = subprocess.run(cmd, env={**os.environ, **(env or {})}, capture_output=True, text=True)
    if check and r.returncode != 0:
        err = r.stderr.strip() or r.stdout.strip()
        for i, a in enumerate(cmd):
            if i and cmd[i - 1] in SECRET_OPTS:
                err = err.replace(a, "***")
        sys.exit(f"mld-autoenroll: {shown(cmd)}: {err}")
    if not quiet and r.stderr.strip():
        print(r.stderr.strip(), file=sys.stderr)
    return r


def tpm2_pkcs11_lib(candidates=None):
    if candidates is None:
        names = ["libtpm2_pkcs11.so", "libtpm2_pkcs11.so.1"]
        dirs = [os.environ.get("PKCS11_DIR"), "/usr/lib64/pkcs11", "/usr/lib/x86_64-linux-gnu/pkcs11"]
        candidates = [f"{d}/{n}" for d in dirs if d for n in names]
    for path in candidates:
        if os.path.exists(path):
            return path
    sys.exit("libtpm2_pkcs11.so not found in: " + ", ".join(candidates))


def ldap(c, base, scope, filt, attrs, sd=False):
    """ldapsearch with Kerberos (GSSAPI). Returns a list of {attr: [bytes]}, attribute names in lower case."""
    cmd = ["ldapsearch", "-Q", "-N", "-LLL", "-o", "ldif-wrap=no", "-Y", "GSSAPI", "-H", f"ldap://{c['DC_FQDN']}",
           "-b", base, "-s", scope]
    if sd:
        cmd += ["-E", SD_FLAGS]
    out = subprocess.run(cmd + [filt] + attrs, capture_output=True, check=True).stdout.decode()
    entries, cur = [], {}
    for line in out.splitlines() + [""]:
        if not line:
            if cur:
                entries.append(cur)
            cur = {}
            continue
        if line.startswith("#"):
            continue
        if ":: " in line:
            k, v = line.split(":: ", 1)
            val = base64.b64decode(v)
        elif ": " in line:
            k, v = line.split(": ", 1)
            val = v.encode()
        else:
            continue
        cur.setdefault(k.lower(), []).append(val)
    return entries


def sid_str(raw):
    # impacket only for AD: IDP=freeipa does not install it.
    from impacket.ldap import ldaptypes
    return ldaptypes.LDAP_SID(data=raw).formatCanonical()


def rights(sd_raw, sids):
    """Enroll/autoenroll rights that the DACL gives to any of sids (deny wins)."""
    from impacket.ldap import ldaptypes
    from impacket.uuid import bin_to_string
    sd = ldaptypes.SR_SECURITY_DESCRIPTOR(data=sd_raw)
    allow, deny = set(), set()
    for ace in sd["Dacl"].aces:
        t, a = ace["AceType"], ace["Ace"]
        if t not in (0x00, 0x01, 0x05, 0x06) or a["Sid"].formatCanonical() not in sids:
            continue
        mask = a["Mask"]["Mask"]
        obj = None
        if t in (0x05, 0x06) and a["Flags"] & 0x1:  # ACE_OBJECT_TYPE_PRESENT
            obj = bin_to_string(a["ObjectType"]).lower()
        if mask & 0x10000000 or (mask & 0x000F01FF) == 0x000F01FF:  # GENERIC_ALL, full control
            got = {"enroll", "autoenroll"}
        elif mask & 0x100:  # ADS_RIGHT_DS_CONTROL_ACCESS
            got = {"enroll", "autoenroll"} if obj is None else ({RIGHT_NAMES.get(obj)} - {None})
        else:
            continue
        (allow if t in (0x00, 0x05) else deny).update(got)
    return allow - deny


def kinit_machine():
    os.environ["KRB5CCNAME"] = "FILE:/run/mld-machine.ccache"
    host = run(["hostname", "-s"]).stdout.strip().upper()
    c = conf()
    run(["kinit", "-k", f"{host}$@{c['REALM']}"])
    return host


def not_qualified(t, sids, machine):
    """The reasons why the template entry T does not qualify. Empty: it qualifies."""
    flags = int(t.get("flags", [b"0"])[0]) & 0xFFFFFFFF
    enroll_flags = int(t.get("mspki-enrollment-flag", [b"0"])[0]) & 0xFFFFFFFF
    schema = int(t.get("mspki-template-schema-version", [b"1"])[0])
    why = []
    if machine and not flags & CT_FLAG_MACHINE_TYPE:
        why.append("user template")
    if not machine and flags & CT_FLAG_MACHINE_TYPE:
        why.append("machine template")
    if schema < 2:
        why.append(f"schema {schema}")
    if not enroll_flags & CT_FLAG_AUTO_ENROLLMENT:
        why.append("no autoenroll flag")
    got = rights(t["ntsecuritydescriptor"][0], sids) if "ntsecuritydescriptor" in t else set()
    if not {"enroll", "autoenroll"} <= got:
        why.append(f"rights {sorted(got) or 'none'}")
    return why


def qualifying_templates(c, account, machine=True):
    pks = f"CN=Public Key Services,CN=Services,CN=Configuration,{c['DOMAIN_DN']}"
    me = ldap(c, c["DOMAIN_DN"], "sub", f"(sAMAccountName={account})", ["objectSid"])
    if not me:
        sys.exit(f"mld-autoenroll: {account} not found in AD")
    dn = me[0]["dn"][0].decode()
    sids = {sid_str(me[0]["objectsid"][0])} | WELL_KNOWN
    tg = ldap(c, dn, "base", "(objectClass=*)", ["tokenGroups"])
    sids |= {sid_str(s) for s in tg[0].get("tokengroups", [])}

    published = set()
    for ca in ldap(c, f"CN=Enrollment Services,{pks}", "one", "(objectClass=pKIEnrollmentService)",
                   ["cn", "certificateTemplates"]):
        published |= {t.decode() for t in ca.get("certificatetemplates", [])}

    result = []
    for name in sorted(published):
        found = ldap(c, f"CN=Certificate Templates,{pks}", "one", f"(cn={name})",
                     ["flags", "msPKI-Enrollment-Flag", "msPKI-Template-Schema-Version", "nTSecurityDescriptor"],
                     sd=True)
        if not found:
            continue
        why = not_qualified(found[0], sids, machine)
        print(f"  {'yes' if not why else 'no '}  {name}" + (f" ({', '.join(why)})" if why else ""))
        if not why:
            result.append(name)
    return result


def getcert(p, sub, *args):
    """getcert SUB for the system certmonger, or with -s for the session certmonger of the user."""
    return ["getcert", sub] + (["-s"] if p["session"] else []) + list(args)


def tracked(p):
    """certmonger request IDs of this tool (prefix mld-)."""
    out = run(getcert(p, "list", "-c", p["ca"]), check=False, quiet=True).stdout
    return {l.split("'")[1] for l in out.splitlines() if l.startswith("Request ID '") and "'mld-" in l}


def store_contents(store):
    """Token labels and primary object IDs in the tpm2-pkcs11 store (its SQLite database)."""
    db = os.path.join(store, "tpm2_pkcs11.sqlite3")
    if not os.path.exists(db):
        return set(), []
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    try:
        labels = {r[0] for r in con.execute("SELECT label FROM tokens")}
        pids = sorted(r[0] for r in con.execute("SELECT id FROM pobjects"))
    finally:
        con.close()
    return labels, pids


def store_repair(store):
    """An interrupted tpm2_ptool init leaves a database with tables but no schema version. Each later init then
    fails in _get_version ("'NoneType' object is not subscriptable", tpm2-pkcs11 1.10.1, seen 2026-11-18).
    Move such a database away when it has no rows: then it holds no key. Else stop and change nothing."""
    db = os.path.join(store, "tpm2_pkcs11.sqlite3")
    if not os.path.exists(db):
        return
    # immutable=1: read without the journal. With mode=ro alone, sqlite tries to roll back the left-over journal
    # and fails ("attempt to write a readonly database").
    con = sqlite3.connect(f"file:{db}?mode=ro&immutable=1", uri=True)
    try:
        tables ={r[0] for r in con.execute("SELECT name FROM sqlite_master WHERE type = 'table'")}
        if "schema" not in tables or con.execute("SELECT count(*) FROM schema").fetchone()[0]:
            return
        rows = sum(con.execute(f"SELECT count(*) FROM {t}").fetchone()[0]
                   for t in ("tokens", "pobjects", "tobjects", "sealobjects") if t in tables)
    finally:
        con.close()
    if rows:
        sys.exit(f"mld-autoenroll: {db} has no schema version but {rows} rows: repair it by hand")
    stamp = time.strftime("%Y%m%d%H%M%S")
    for f in (db, f"{db}-journal"):
        if os.path.exists(f):
            os.rename(f, f"{f}.broken-{stamp}")
    print(f"{db}: no schema version and no rows (interrupted init), moved to *.broken-{stamp}")


# certmonger post-save command. The wrapper has the type certmonger_unconfined_exec_t (Fedora fcontexts.list).
PRUNE = "/usr/local/libexec/mld-cert-prune"
CKA_CLASS, CKA_VALUE, CKA_ID, CKO_CERTIFICATE = 0, 17, 258, 1


def not_after(der):
    out = subprocess.run(["openssl", "x509", "-inform", "DER", "-noout", "-enddate"], input=der,
                         capture_output=True, check=True).stdout.decode()
    return time.mktime(time.strptime(out.strip().split("=", 1)[1], "%b %d %H:%M:%S %Y %Z"))


def prune(p):
    """A renewal (getcert resubmit, auto-renew) adds the new certificate to the token and keeps the old one,
    with the same CKA_ID (seen 2026-11-18). snx-rs uses all certificates of the slot. Keep the newest per CKA_ID.
    A certificate object is a row of the tpm2-pkcs11 database only: no TPM object belongs to it."""
    import yaml
    db = os.path.join(p["store"], "tpm2_pkcs11.sqlite3")
    if not os.path.exists(db):
        return
    con = sqlite3.connect(db, timeout=30)
    try:
        tok = con.execute("SELECT id FROM tokens WHERE label = ?", (p["token"],)).fetchone()
        if tok is None:
            return
        by_id = {}
        for oid, attrs in con.execute("SELECT id, attrs FROM tobjects WHERE tokid = ?", tok):
            a = yaml.safe_load(attrs)
            if a.get(CKA_CLASS) == CKO_CERTIFICATE and CKA_VALUE in a:
                by_id.setdefault(a.get(CKA_ID), []).append((not_after(bytes.fromhex(a[CKA_VALUE])), oid))
        old = [oid for certs in by_id.values() for _, oid in sorted(certs)[:-1]]
        for oid in old:
            con.execute("DELETE FROM tobjects WHERE id = ?", (oid,))
        con.commit()
    finally:
        con.close()
    if old:
        print(f"token {p['token']}: removed {len(old)} replaced certificate(s)")


def setup(p, who):
    c = conf()
    if p["session"]:
        relinked = link_to_device(p["home"], ".tpm2_pkcs11", p["store"])
        relinked |= link_to_device(p["home"], ".config/certmonger", f"{p['state']}/certmonger")
        if relinked:
            # The session certmonger (D-Bus activated) keeps the old state directory open.
            # The next getcert starts it again.
            run(["pkill", "-u", str(os.getuid()), "-x", "certmonger"], check=False, quiet=True)
    os.makedirs(p["store"], mode=0o700, exist_ok=True)
    os.makedirs(os.path.dirname(p["pin"]), mode=0o700, exist_ok=True)
    # modutil loads the module, and the module searches its store. With the real HOME (ssh, login shell)
    # it finds no store ("Could not find or create a pkcs11 store"). A direct child gets the variable.
    env = {"TSS2_LOG": "all+NONE", "TPM2_PKCS11_STORE": p["store"]}

    if not os.path.exists(p["pin"]):
        old = os.umask(0o077)
        with open(p["pin"], "w") as f:
            f.write(secrets.token_hex(16))
        os.umask(old)
    pin = open(p["pin"]).read().strip()

    store_repair(p["store"])
    labels, pids = store_contents(p["store"])
    if p["token"] not in labels:
        if pids:
            pid = str(pids[0])
        else:
            init = run(["tpm2_ptool", "init", "--path", p["store"]], env=env).stdout
            pid = next(l.split(":")[1].strip() for l in init.splitlines() if l.strip().startswith("id:"))
        # The SO PIN is not used again: a new random one, not stored.
        run(["tpm2_ptool", "addtoken", "--pid", pid, "--label", p["token"], "--userpin", pin,
             "--sopin", secrets.token_hex(16), "--path", p["store"]], env=env)
        print(f"TPM token {p['token']} made in {p['store']}")

    db = p["nssdb"].removeprefix("sql:")
    os.makedirs(db, mode=0o700, exist_ok=True)
    if not os.path.exists(f"{db}/cert9.db"):
        run(["certutil", "-N", "-d", p["nssdb"], "--empty-password"])
    lib = tpm2_pkcs11_lib()
    mods = run(["modutil", "-dbdir", p["nssdb"], "-list"], env=env, check=False, quiet=True).stdout
    # Fedora NSS loads tpm2-pkcs11 through p11-kit-proxy. A second load of the module fails with 0x191
    # (CKR_CRYPTOKI_ALREADY_INITIALIZED), so add the module only when NSS does not show the token yet.
    visible = any(l.strip() == f"token: {p['token']}" for l in mods.splitlines())
    if "mld-tpm2" not in mods and not visible:
        # modutil asks for confirmation when a browser could run; -force skips the question.
        run(["modutil", "-dbdir", p["nssdb"], "-add", "mld-tpm2", "-libfile", lib, "-force"], env=env)

    if not p["session"]:
        # An older version set TPM2_PKCS11_STORE here. certmonger does not pass it on, so it has no use.
        dropin = "/etc/systemd/system/certmonger.service.d/mld.conf"
        if os.path.exists(dropin):
            os.remove(dropin)
            run(["systemctl", "daemon-reload"])
            run(["systemctl", "restart", "certmonger.service"])
        run(["systemctl", "enable", "--now", "certmonger.service"])

    if freeipa(c) and not p["session"]:
        # ipa-client-install adds the CA IPA (ipa-submit with the host keytab).
        cas = run(getcert(p, "list-cas", "-c", "IPA"), check=False, quiet=True).stdout
        if "CA 'IPA'" not in cas:
            sys.exit("mld-autoenroll: certmonger has no CA 'IPA': ipa-client-install did not finish")
        print("certmonger CA IPA (from ipa-client-install)")
        return
    if freeipa(c):
        sub = next((x for x in IPA_SUBMIT if os.path.exists(x)), None)
        if sub is None:
            sys.exit("mld-autoenroll: ipa-submit not found in: " + ", ".join(IPA_SUBMIT))
        # -K: the login ticket of the user. -T: the profile that the CA ACL mld-users allows.
        helper = f"{sub} -K -T mldUserCert"
    else:
        helper = f"/usr/local/libexec/mld-cm-submit {who} {c.get('PKI_ENROLL', 'web')}"
    cas = run(getcert(p, "list-cas", "-c", p["ca"]), check=False, quiet=True).stdout
    verb = "modify-ca" if f"CA '{p['ca']}'" in cas else "add-ca"
    run(getcert(p, verb, "-c", p["ca"], "-e", helper))
    print(f"certmonger CA {p['ca']}: {helper}")


def stuck(p, rid):
    out = run(getcert(p, "list", "-i", rid), check=False, quiet=True).stdout
    return "stuck: yes" in out


def enroll_ipa(p, who):
    """One certificate for the machine or the user. The server (CA ACL, profile) decides, not the client."""
    d = ipa_default()
    if who == "machine":
        host = d["host"]
        rid, args = "mld-ipa-machine", ["-K", f"host/{host}", "-D", host, "-N", f"CN={host}", "-n", "mld-machine"]
    else:
        if run(["klist", "-s"], check=False, quiet=True).returncode != 0:
            sys.exit("mld-autoenroll: no Kerberos ticket: log in with the IPA password or run kinit")
        account = os.environ.get("USER") or run(["id", "-un"]).stdout.strip()
        rid, args = "mld-ipa-user", ["-K", f"{account}@{d['realm']}", "-N", f"CN={account}", "-n", "mld-user"]
    post = f"{PRUNE} {who}"
    have = tracked(p)
    if rid in have and stuck(p, rid):
        run(getcert(p, "stop-tracking", "-i", rid))
        print(f"  {rid} was stuck: requested again")
    elif rid in have:
        # A request from before the post-save command gets it now (start-tracking -i changes the request).
        run(getcert(p, "start-tracking", "-i", rid, "-C", post))
        print(f"  {rid}: tracked")
        prune(p)
        return
    run(getcert(p, "request", "-I", rid, "-c", p["ca"], "-d", p["nssdb"], "-t", p["token"], "-p", p["pin"],
                "-G", "rsa", "-g", "2048", "-C", post, *args, "-w"))
    print(f"  requested {rid} from CA {p['ca']}")


def enroll(p, who):
    c = conf()
    if freeipa(c):
        enroll_ipa(p, who)
        return
    domain = c["DC_FQDN"].split(".", 1)[1]
    if who == "machine":
        host = kinit_machine()
        account, subject = f"{host}$", f"CN={host.lower()}.{domain}"
    else:
        # The login ticket of the user (sssd, krb5_ccname_template). No ticket, no enrollment.
        if run(["klist", "-s"], check=False, quiet=True).returncode != 0:
            sys.exit("mld-autoenroll: no Kerberos ticket: log in with the AD password or run kinit")
        account = os.environ.get("USER") or run(["id", "-un"]).stdout.strip()
        subject = f"CN={account}"
    print(f"templates for {account}:")
    want = qualifying_templates(c, account, machine=(who == "machine"))
    have = tracked(p)
    post = f"{PRUNE} {who}"
    for name in want:
        rid = f"mld-{name}"
        if rid in have and stuck(p, rid):
            run(getcert(p, "stop-tracking", "-i", rid))
            print(f"  {rid} was stuck: requested again")
        elif rid in have:
            # A request from before the post-save command gets it now (start-tracking -i changes the request).
            run(getcert(p, "start-tracking", "-i", rid, "-C", post))
            continue
        run(getcert(p, "request", "-I", rid, "-c", p["ca"], "-T", name,
                    "-d", p["nssdb"], "-n", name, "-t", p["token"], "-p", p["pin"],
                    "-G", "rsa", "-g", "2048", "-N", subject, "-C", post, "-w"))
        print(f"  requested {name} (certmonger {rid})")
    for rid in sorted(have - {f"mld-{n}" for n in want}):
        run(getcert(p, "stop-tracking", "-i", rid))
        print(f"  stopped {rid}: the template does not qualify any more")
    prune(p)


def status(p):
    out = run(getcert(p, "list", "-c", p["ca"]), check=False, quiet=True).stdout
    keep = ("Request ID", "status:", "stuck:", "key pair storage:", "certificate:", "CA:", "issuer:",
            "subject:", "expires:", "ca-error:", "template", "profile:")
    print("\n".join(l for l in out.splitlines() if l.strip().startswith(keep)))


def main():
    args = sys.argv[1:]
    if args in (["setup", "machine"], ["machine"], ["prune"], ["prune", "machine"]) and os.getuid() != 0:
        sys.exit("mld-autoenroll: machine needs root")
    if args and "user" in args and os.getuid() == 0:
        sys.exit("mld-autoenroll: run user mode as the AD user")
    if args == ["setup", "machine"]:
        setup(profile("machine"), "machine")
    elif args == ["machine"]:
        enroll(profile("machine"), "machine")
    elif args == ["setup", "user"]:
        setup(profile("user"), "user")
    elif args == ["user"]:
        enroll(profile("user"), "user")
    elif args == ["status"]:
        status(profile("machine"))
    elif args == ["status", "user"]:
        status(profile("user"))
    elif args in (["prune"], ["prune", "machine"]):
        prune(profile("machine"))
    elif args == ["prune", "user"]:
        prune(profile("user"))
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
