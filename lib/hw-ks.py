#!/usr/bin/env python3
"""Kickstart for real hardware, made from the rendered lab kickstart (one package list for both).

Usage: hw-ks.py IN_KS OUT_KS
Anaconda asks for storage (LUKS passphrase), user and host name. The USB stick holds no secret.
The %post --nochroot step reads the files from the install medium (/run/install/repo) and the offline
join blob of the typed host name.
"""
import re
import sys

DROP = ("text", "zerombr", "clearpart", "part ", "volgroup", "logvol", "user ", "rootpw", "network ")
NOCHROOT = r"""%post --nochroot --erroronfail --log=/mnt/sysroot/root/ks-post-nochroot.log
install -d -m 700 /mnt/sysroot/etc/mld
cp -a /run/install/repo/mld/. /mnt/sysroot/etc/mld/
chmod 700 /mnt/sysroot/etc/mld
# The blob of this computer name. Without it, the first boot stops before the join (mld-firstboot join FILE).
h=$(tr a-z A-Z < /mnt/sysroot/etc/hostname)
if [ -f "/run/install/repo/odj/$h.txt" ]; then install -m 600 "/run/install/repo/odj/$h.txt" /mnt/sysroot/etc/mld/odj.txt; fi
# The admin name is the one typed in Anaconda (first user, UID 1000).
u=$(awk -F: '$3 == 1000 { print $1 }' /mnt/sysroot/etc/passwd)
if [ -z "$u" ]; then echo "create an administrator user in Anaconda" >&2; exit 1; fi
sed -i '/^CLIENT_ADMIN=/d' /mnt/sysroot/etc/mld/config.env
printf 'CLIENT_ADMIN=%s\n' "$u" >> /mnt/sysroot/etc/mld/config.env
if [ -d /mnt/sysroot/etc/mld/sb ]; then chmod 700 /mnt/sysroot/etc/mld/sb; chmod 600 /mnt/sysroot/etc/mld/sb/*; fi
%end
"""

src, dst = sys.argv[1], sys.argv[2]
out, section, skip = [], None, False
for line in open(src).read().splitlines():
    if line.startswith("# Rendered by build.sh"):
        continue
    if line.startswith("%"):
        section = line.split()[0]
        if section == "%post" and "--nochroot" in line:
            out.append(NOCHROOT.rstrip("\n"))
            skip = True
            continue
    if skip:
        if line == "%end":
            skip = False
        continue
    if section in (None, "%end") and line.startswith(DROP):
        while out and out[-1].startswith("#"):
            out.pop()
        continue
    if section == "%packages" and line.strip() == "qemu-guest-agent":
        continue
    if line.startswith("services "):
        line = re.sub(r",?qemu-guest-agent", "", line)
    if "qemu-guest-agent.service" in line:
        line = line.replace(" qemu-guest-agent.service", "")
    if line.startswith("grubby ") or line.startswith("# Serial console"):
        continue
    out.append(line)
    if line == "%end":
        section = None

with open(dst, "w") as f:
    f.write("# Real hardware (build.sh client hw-iso). No secrets: Anaconda asks for them.\n")
    f.write("\n".join(out) + "\n")
