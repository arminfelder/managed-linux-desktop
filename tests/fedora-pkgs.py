# Fedora package names that the client installs: the kickstart %packages section and every pkg_install call
# that can run on Fedora. No network.
#   python3 -I tests/fedora-pkgs.py ROOT             prints "name<TAB>source" lines, exit 1 on a name it cannot resolve
#   python3 -I tests/fedora-pkgs.py ROOT FIXTURE     exit 1 when a name is not in FIXTURE (tests/fixtures/fedora-pkgs.txt)
import os
import re
import sys

# From third-party repositories (client/mld/apps/google-chrome.repo, client/mld/vpn/snx-rs.repo), not Fedora.
THIRD_PARTY = {"google-chrome-stable", "snx-rs"}
NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9+._-]*")
ARM = re.compile(r"^[ \t]*[A-Za-z0-9_|*-]+\)")


def ks_packages(path):
    out, inside = [], False
    with open(path) as f:
        for n, line in enumerate(f, 1):
            s = line.strip()
            if s.startswith("%packages"):
                inside = True
                continue
            if inside and s.startswith("%end"):
                inside = False
            if not inside or not s or s[0] in "#@-" or "@@" in s:
                continue
            out.append((s.split()[0], "%s:%d" % (path, n)))
    return out


def ubuntu_lines(lines):
    """Set of 0-based line numbers in an ubuntu) case arm or behind an '= ubuntu' test (same rules as in_ubuntu_arm)."""
    res, u = set(), False
    for i, line in enumerate(lines):
        if re.match(r"^[ \t]*#", line):
            if u:
                res.add(i)
            continue
        if re.match(r"^[ \t]*esac([ \t;]|$)", line):
            u = False
        if ARM.match(line):
            u = line.lstrip().startswith("ubuntu)")
        if u or re.search(r'CLIENT_DISTRO(:-ubuntu)?\}?"? = "?ubuntu', line):
            res.add(i)
        if re.search(r";;[ \t]*$", line):
            u = False
    return res


def functions(lines):
    """name -> (first, last) line numbers of each top-level function."""
    out, cur = {}, None
    for i, line in enumerate(lines):
        m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)\(\)[ \t]*\{", line)
        if m:
            cur = (m.group(1), i)
        elif cur and line.startswith("}"):
            out[cur[0]] = (cur[1], i)
            cur = None
    return out


def shell_packages(root):
    out, bad = [], []
    files = []
    for dp, _, fs in os.walk(os.path.join(root, "client", "mld")):
        files += [os.path.join(dp, f) for f in fs if f.endswith(".sh")]
    texts = {}
    for p in sorted(files):
        with open(p) as f:
            texts[p] = f.read().split("\n")
    # A function whose callers all run only on Ubuntu is Ubuntu-only too.
    ubu = {p: ubuntu_lines(t) for p, t in texts.items()}
    funcs = {}
    for p, t in texts.items():
        for name, rng in functions(t).items():
            funcs[name] = (p, rng)
    ubuntu_only = set()
    for name, (p, (a, b)) in funcs.items():
        calls = [(q, i) for q, t in texts.items() for i, l in enumerate(t)
                 if re.search(r"(^|[^A-Za-z0-9_-])%s([^A-Za-z0-9_(-]|$)" % re.escape(name), l)
                 and not (q == p and a <= i <= b) and not l.lstrip().startswith("#")]
        if calls and all(i in ubu[q] for q, i in calls):
            ubuntu_only.add(name)
    for p, t in texts.items():
        rel = os.path.relpath(p, root)
        skip = set(ubu[p])
        for name, (q, (a, b)) in funcs.items():
            if q == p and name in ubuntu_only:
                skip.update(range(a, b + 1))
        arrays = {}
        joined = []
        i = 0
        while i < len(t):
            start, line = i, t[i]
            while line.endswith("\\") and i + 1 < len(t):
                i += 1
                line = line[:-1] + " " + t[i]
            # Array values can go on over lines up to the closing parenthesis.
            m = re.search(r"\b([A-Z_][A-Z0-9_]*)=\(([^)]*)$", line)
            while m and i + 1 < len(t):
                i += 1
                line += " " + t[i]
                m = re.search(r"\b([A-Z_][A-Z0-9_]*)=\(([^)]*)$", line)
            joined.append((start, line))
            i += 1
        for start, line in joined:
            if start in skip:
                continue
            for m in re.finditer(r"\b([A-Z_][A-Z0-9_]*)=\(([^)]*)\)", line):
                arrays.setdefault(m.group(1), []).extend(m.group(2).split())
        for start, line in joined:
            if start in skip or line.lstrip().startswith("#"):
                continue
            for m in re.finditer(r"(?:^|[\s;&|(])pkg_install\s+([^;&|)\n]+)", line):
                src = "%s:%d" % (rel, start + 1)
                for w in m.group(1).split():
                    if w.startswith("#"):
                        break
                    a = re.fullmatch(r'"?\$\{([A-Z_][A-Z0-9_]*)\[@\]\}"?', w)
                    if a and a.group(1) in arrays:
                        out += [(x, src) for x in arrays[a.group(1)]]
                    elif NAME.fullmatch(w):
                        out.append((w, src))
                    else:
                        bad.append("%s: cannot resolve %s" % (src, w))
    return out, bad


def main():
    root = sys.argv[1]
    names = ks_packages(os.path.join(root, "client", "ks.cfg.tmpl"))
    sh, bad = shell_packages(root)
    names += sh
    for b in bad:
        print(b, file=sys.stderr)
    if len(sys.argv) < 3:
        for n, src in sorted(set(names)):
            print("%s\t%s" % (n, src))
        return 1 if bad else 0
    with open(sys.argv[2]) as f:
        known = {l.split()[0] for l in f if l.strip() and not l.startswith("#")}
    missing = sorted({(n, src) for n, src in names if n not in known and n not in THIRD_PARTY})
    for n, src in missing:
        print("not in Fedora 45: %s (%s)" % (n, src))
    return 1 if missing or bad else 0


if __name__ == "__main__":
    sys.exit(main())
