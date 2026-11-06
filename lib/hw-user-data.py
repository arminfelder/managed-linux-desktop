#!/usr/bin/env python3
"""Autoinstall for real hardware, made from the rendered lab autoinstall (one package list for both).

Usage: hw-user-data.py IN OUT
The installer asks for the identity (host name, admin user and password) and the storage (LVM + LUKS passphrase).
The USB stick holds no password and no passphrase. The late-commands copy /cdrom/mld and the offline join blob of
the typed host name (/cdrom/odj/NAME.txt).
"""
import sys
import yaml

src, dst = sys.argv[1], sys.argv[2]
doc = yaml.safe_load(open(src))
ai = doc["autoinstall"]

ai["interactive-sections"] = ["identity", "storage"]
# No identity section: the installer schema wants a password in it ("Malformed autoinstall in 'identity' section"
# without one). As an interactive section, the installer asks for host name, user and password on its own screen.
ai.pop("identity", None)
ai.pop("storage", None)
ai["packages"] = [p for p in ai["packages"] if p != "qemu-guest-agent"]
ai["late-commands"] = [
    "install -d -m 700 /target/etc/mld",
    "cp -a /cdrom/mld/. /target/etc/mld/",
    "chmod 700 /target/etc/mld",
    # The blob of this computer name. Without it, the first boot stops before the join (mld-firstboot join FILE).
    "h=$(tr a-z A-Z < /target/etc/hostname); "
    "if [ -f \"/cdrom/odj/$h.txt\" ]; then install -m 600 \"/cdrom/odj/$h.txt\" /target/etc/mld/odj.txt; fi",
    # cloud-init deletes the password of the installer user at the first boot (passwd -d). phase_admin_pw sets the
    # hash again from this copy. The admin name is the one typed in the installer.
    "u=$(awk -F: '$3 == 1000 { print $1 }' /target/etc/passwd); "
    "if [ -n \"$u\" ]; then printf 'CLIENT_ADMIN=%s\\n' \"$u\" >> /target/etc/mld/config.env; "
    "awk -F: -v u=\"$u\" '$1 == u { print $2 }' /target/etc/shadow > /target/etc/mld/admin-hash; "
    "chmod 600 /target/etc/mld/admin-hash; fi",
    "while read -r src dst mode; do case \"$src\" in \"\"|\"#\"*) continue ;; esac; "
    "[ \"$dst\" = - ] || install -D -m \"$mode\" \"/target/etc/mld/$src\" \"/target$dst\"; "
    "done < /target/etc/mld/install.list",
    "curtin in-target -- systemctl enable mld-firstboot.service",
]
with open(dst, "w") as f:
    f.write("#cloud-config\n# Real hardware (build.sh client hw-iso). No secrets: the installer asks for them.\n")
    yaml.safe_dump(doc, f, sort_keys=False, default_flow_style=False, width=1000)
