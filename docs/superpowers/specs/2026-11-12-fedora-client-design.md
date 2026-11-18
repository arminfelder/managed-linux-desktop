# Fedora client: design

Date: 2026-11-12. Status: draft for review.

## Intent

The organisation runs Red Hat servers. A managed Linux desktop from the Red Hat
ecosystem (dnf, RPM, SELinux, kickstart) fits that estate better than Ubuntu
for some sites. The lab must show that the full managed-desktop pattern
(Secure Boot, LUKS2 + TPM2, AD offline join, CIFS home, PKI autoenrollment,
GPO, VPN, browsers, branding, updates) works on Fedora too, so the choice can
be made on facts.

Fedora, not RHEL/Alma/Rocky Workstation: the user decided that Fedora is the
better desktop in the Red Hat ecosystem (newer GNOME/KDE, kernel, drivers).
The shorter lifecycle is accepted.

## Goals

- New setting `CLIENT_DISTRO=ubuntu|fedora` in `lab.env` (`env.example` +
  `lib/settings.sh`, `S_CHOICES`), default `ubuntu`. Existing labs behave as
  today.
- Fedora 45 (current stable; `samba-gpupdate 4.25.1-1.fc45` is in the stable
  repo, packages.fedoraproject.org, checked 2026-11-12).
- **Full parity** with the Ubuntu client: every topic in `client/mld`
  (`boot ad cert home apps desktop gpo vpn update brand`), `UKI=1` with
  `UKI_TRUST=db|mok`, TPM2 and FIDO2 LUKS enrollment, offline domain join,
  certmonger autoenrollment (machine + user, TPM keys), samba-gpupdate,
  snx-rs with the TPM machine certificate, Firefox + Chrome with AD CA trust
  and Kerberos settings, O365 launchers, Plymouth/login branding, nightly
  patch updates with conditional reboot, `client hw-iso` for real hardware,
  and `client verify` with equivalent checks.
- **SELinux enforcing.** Every denial the lab hits is fixed with a file
  context, a boolean, or a small policy module shipped in `client/mld`
  (for example `mld.te`). Never `permissive`, never `setenforce 0`, never a
  permissive domain. `client verify` checks `getenforce` = `Enforcing` and no
  AVC denials since boot (`ausearch -m AVC,USER_AVC -ts boot`).
  - Scope (user decision): the lab's own scripts and units (`mld-*`) run
    unconfined (`unconfined_service_t`). Fixes go only where a confined
    stock domain (certmonger, sssd, cifs.upcall, gdm/sddm, snx-rs, …) is
    denied: file contexts, booleans, one small module. No new confined
    domains for lab components.
  - Upstream denials (designer's call, user may override): a denial from a
    stock Fedora package that the lab does not cause goes on a documented
    ignore list in `client verify` (each entry: AVC match + Fedora bug
    link). No policy module that widens a stock domain for it.
- Both desktops: `CLIENT_DE=gnome|kde` keeps working on Fedora.

## Non-goals

- **No major-version upgrade** (45 → 46) automation or command. Only patch
  updates inside the release. A rebuild is the path to a new release.
  Consequence to document: Fedora 45 is end-of-life about one month after
  Fedora 47 is out (roughly 13 months after its release).
- No RHEL/Alma/Rocky client.
- No change on the DC beyond what Fedora strictly needs (expected: none).
- No Ubuntu-like layout on Fedora GNOME (see Desktop).
- No mixed distro per client VM; one client = one distro. A second client of
  the other distro needs its own work tree (as today for a second client,
  `lab.env` path is fixed at `build.sh:58`).

## Anti-goals (a failure even if it works)

- SELinux disabled or permissive to make something pass.
- A Fedora feature silently skipped. A feature that cannot work the same way
  gets a documented substitute and a `client verify` check, or an explicit
  "open" entry in CLAUDE.md Gotchas (as Chrome Kerberos is today).
- A second copy of the client tree. Duplicated topic scripts drift.
- The Ubuntu client regresses. Every change keeps the Ubuntu path working;
  render tests run for both distros.
- Unpinned third-party repo keys (snx-rs, Chrome bootstrap) where Ubuntu
  pins them today.

## Constraints

- Guest agent stays the only control path (`guest-exec.sh`, `guest_run`).
- Same CIDATA / `install.list` / `client resume` model.
- `virsh` does not work in the Claude sandbox; the user runs libvirt steps
  with `!`. Render tests run in a copy under `$TMPDIR` (CLAUDE.md Checks).
- Repo conventions: `@@NAME@@` templates via `render()`, `set -E` in
  firstboot, STE-style comments, CLAUDE.md Gotchas updated with each
  confirmed fact.
- Ubuntu remains the default and the reference behaviour.

## Decided parts of the how

### Selection and media

- `CLIENT_DISTRO` derived in `lib/config.sh` like `CLIENT_DE`: it sets the
  package names, the desktop group, the display manager unit, the installer
  type and the os-variant list.
- `FEDORA_ISO` / `FEDORA_URL` in `env.example` next to `UBUNTU_ISO`.
  `build.sh fetch`/`check`/`pin` handle the ISO of the selected distro
  (Fedora publishes a CHECKSUM file with a GPG signature).
- A built client records its distro (`config.env`); `client resume` on a
  client of the other distro fails with "rebuild needed", like
  `desktop_check_de`.

### Code layout (builder's call, already chosen)

- One `client/mld` tree. A small distro layer in `firstboot.sh` (or a
  sourced `client/mld/distro.sh`): `pkg_install`, `pkg_installed`,
  `pkg_purge`, repo install, and path variables (initrd path, shim path,
  pkcs11 module dir, PAM file names). Topic `phase.sh` files branch on
  `$CLIENT_DISTRO` only where the work differs (installer hooks, PAM,
  updates, repos, desktop specifics).
- Distro-specific data files live in the topic folder with a suffix or
  subfolder (`apps/google-chrome.repo`, `vpn/snx-rs.repo`,
  `update/automatic.conf`). `install.list` gets a distro column or a
  per-distro list; the builder chooses, but there stays **one** mechanism
  for CIDATA, the install and `client resume`.

### Installer

- Anaconda kickstart instead of subiquity autoinstall: `client/ks.cfg.tmpl`
  rendered by `render()`, with the same content as `user-data.tmpl`
  (hostname, admin user + hash, timezone, DHCP with DNS = DC, ESP + /boot +
  LUKS2 + LVM root, package list, copy `/etc/mld` from CIDATA, install.list,
  enable `mld-firstboot` + `qemu-guest-agent`, serial console args via
  `grubby`, `mld-uki all`).
- Partitioning: `autopart --type=lvm --encrypted --luks-version=luks2` (or
  explicit `part`/`logvol` to keep the Ubuntu layout and a 1 GB ESP for
  UKIs); LUKS passphrase from `LUKS_PASSPHRASE`.
- Medium (designer's call, not the user's): **Fedora Everything netinstall**
  (classic Anaconda). A Live ISO installs the live image and ignores
  `%packages`, and the Workstation web installer does not do the partial
  kickstart that `hw-iso` needs. Packages come from the mirrors at install
  time. Ubuntu does the same today (the desktop and the AD packages are not
  on the live-server ISO), so reproducibility stays the same: `pin` covers
  the boot ISO only.
- The ISO is remastered so the boot entry carries `inst.ks=` (e.g.
  `mkksiso` from lorax, or xorriso + grub.cfg edit like today). CIDATA stays
  a second CD.
- `client vm` keeps `virt-install --noreboot` + `virsh start --console`.
  os-variant list `fedora45 fedora44 … linux2024`.
- No cloud-init on the installed system, so the empty-password bug does not
  exist. `phase_admin_pw` becomes a check only on Fedora; `client verify`
  keeps `passwd -S` = `P`.
- `hw-iso`: a partial kickstart without storage and user sections, so
  Anaconda asks for them; same rules as `lib/hw-user-data.py` (no secrets,
  no qemu-guest-agent, ODJ blob from `/odj/<HOSTNAME>.txt`, typed admin).

### Boot and disk

- dracut is native on Fedora: `90-mld-crypt.conf` and the TPM2/FIDO2 token
  checks with `lsinitrd` stay. initrd path `/boot/initramfs-$kver.img`.
  Re-check whether the `systemd-networkd` / `zzzz-dracut-default.network`
  problem exists on Fedora; keep the mask only if it does.
- Kernel cmdline via `grubby --update-kernel=ALL --args=...` (BLS entries),
  not `/etc/default/grub` + `update-grub`.
- UKI hooks: `/etc/kernel/install.d/<NN>-mld-uki.install` (kernel-install
  `add`/`remove`) instead of `/etc/kernel/postinst.d`/`postrm.d`.
- shim: `\EFI\fedora\shimx64.efi`; `grub-entry.sh` and `uki.sh` take the
  path and the label ("Fedora") from the distro layer.

### Identity, home, PKI

- sssd, krb5, `net offlinejoin`, keytab, pam_mount config, cifs-utils:
  same content; Fedora package names (`sssd-client`, `krb5-workstation`,
  `samba-common-tools`, `pam_mount`, `cifs-utils`, `tpm2-pkcs11`,
  `tpm2-pkcs11-tools`, `tpm2-openssl`, `nss-tools`, `opensc`, `certmonger`,
  `python3-impacket` — the last one exists in F43–45, checked).
- PAM via **authselect**: a custom profile (`authselect create-profile mld
  -b sssd`) that adds `pam_mount` to auth and session, selected `with-mkhomedir`
  when `CIFS_HOME=0`. No direct edits of `/etc/pam.d/system-auth`.
  The `common-session` checks in `ad/phase.sh` and `lib/tests.sh` get the
  Fedora file names.
- pkcs11 module path `/usr/lib64/pkcs11/` (used at `verify-facts.sh:44,72`
  and `autoenroll.py:304`, which today uses `dpkg -L`).
- SELinux items expected (to confirm): CIFS home (`use_samba_home_dirs`),
  `/var/lib/mld-users/*` incl. `Desktop` and `.tpm2_pkcs11`,
  `/etc/tpm2_pkcs11` read by certmonger and snx-rs, `/usr/local/sbin/mld-*`
  run from systemd units, `ExecStopPost=-+mld-home-umount`, `cifs.upcall`
  reading `/tmp/krb5cc_%U`, samba-gpupdate writing browser policies.

### GPO

- `samba-gpupdate` package on Fedora. Confirm which package has the ldb
  `ildap` backend (Ubuntu: `samba-dsdb-modules`); the same "no bind" failure
  must not come back.
- Confirm the Firefox policy path that Fedora's `firefox` reads matches what
  `gp_firefox_ext` writes (`/etc/firefox/policies/policies.json`).

### Apps and VPN

- Firefox: Fedora `firefox` RPM. No extra repo, no pin.
- Chrome: Google RPM repo (`google-chrome.repo`), key pinned like today.
  Chrome Kerberos stays "open" as on Ubuntu.
- snx-rs: upstream DNF repo `https://ancwrd1.github.io/snx-rs/snx-rs.repo`
  + `KEY.gpg` (from ancwrd1.github.io/snx-rs, checked 2026-11-12). The page
  gives no fingerprint: we pin it in the repo file, as on Ubuntu.
  `SNX_RS=0` + `client resume` removes it.

### Desktop

- GNOME: `@workstation-product-environment` (or a minimal equivalent) +
  `gdm.service`. **Stock Fedora GNOME** (user decision): no dock extension,
  no desktop icons. Pins from `pins.list` go to the dash
  (`org.gnome.shell favorite-apps`, dconf default); O365 launchers appear in
  the app grid. The `mld-desktop` user unit (local desktop folder + trusted
  launchers) is not used on Fedora GNOME.
- KDE: `@kde-desktop-environment`. Plasma shows the desktop folder by
  default, so the KDE flow (pins script, desktop folder) stays as on Ubuntu
  (builder's call, already chosen). The display manager on Fedora 45 KDE
  (sddm or Plasma Login Manager) must be confirmed; the "no user list" and
  branded background requirements stay.
- The Ubuntu-only `budgie-sddm-theme` purge does not apply.

### Updates

- Patch updates only: `dnf5-plugin-automatic` with apply enabled, timer
  `dnf5-automatic.timer` (names to confirm on F45), covering Fedora, Chrome
  and snx-rs repos.
- `mld-reboot` keeps its rules (night window, TPM2 crypttab, no firstboot or
  update running, no user session); "reboot needed" comes from
  `dnf needs-restarting -r` instead of `/run/reboot-required`.
- `DPkg::Lock::Timeout` has no dnf equivalent; firstboot and dnf-automatic
  must not run at the same time (e.g. `dnf5-automatic.timer` enabled only at
  the end of firstboot, or an ordering on `mld-firstboot.service`).

### Branding

- Plymouth theme `mld` as today; default via `plymouth-set-default-theme mld`
  (no `update-alternatives`), then the same hash-gated dracut + UKI rebuild.

### Verify

- `client verify` checks the same facts with Fedora sources: `rpm -q`
  instead of `dpkg-query`, dnf-automatic state instead of the apt periodic
  values, authselect profile and features, `getenforce` + no AVC denials,
  `Version: 2` of the LUKS header.

## First task: blockers

Before the bulk of the work, install a plain Fedora 45 VM and confirm:

1. `qemu-guest-agent` allows `guest-exec`, `guest-exec-status`,
   `guest-file-*`. Package check done: see "Probe results 2026-11-12"
   (no filter in the package; a VM run still has to confirm it).
2. The KDE display manager on F45.
3. The package that gives samba-gpupdate the `ildap` ldb backend.

If one of these blocks, stop and update this design.

## Probe results 2026-11-12

Source: `tests/fedora-probe.sh` reads the Fedora 45 repositories (`updates`
first, then `releases`, x86_64 + noarch) and unpacks the RPMs; no VM or
container. Trust: repomd and RPMs are checked only against checksums from the
same HTTPS host, with no GPG check. This is fact-finding, not an install trust
path. These are package facts. They do not show runtime behaviour: the
checks in "First task: blockers" still need one VM run.

1. qemu-guest-agent (`qemu-guest-agent-2:11.1.3-1.fc45.x86_64`).
   `/etc/sysconfig/qemu-ga` has one active line: `FSFREEZE_HOOK_PATHNAME=/etc/qemu-ga/fsfreeze-hook`.
   No `BLACKLIST_RPC`/`FILTER_RPC`. The unit has `EnvironmentFile=/etc/sysconfig/qemu-ga`
   and `ExecStart=/usr/bin/qemu-ga --method=virtio-serial --path=/dev/virtio-ports/org.qemu.guest_agent.0 -F${FSFREEZE_HOOK_PATHNAME} $QEMU_GA_ARGS`.
   `ExecStartPre` only rewrites a `BLACKLIST_RPC=` line into `QEMU_GA_ARGS=--block-rpcs=`.
   Result: the package filters no RPC (`QEMU_GA_FILTER=none`), so the kickstart
   `%post` needs no change for `guest-exec` and `guest-file-*`. Security fact:
   the guest agent then gives root command execution to the host, as on Ubuntu.
   `guest-desktop-agents` (in both desktop groups) also installs `qemu-guest-agent`.
2. KDE display manager (`KDE_DM=plasmalogin`). Group `kde-desktop`
   (via `kde-desktop-environment`) lists `plasma-login-manager-6.8.2-1.fc45`
   (mandatory), `kcm-plasmalogin` (mandatory), `kde-settings-plasmalogin-44.0-1.fc45` (default).
   `sddm-0.21.0-16.fc45` is still in the repository but no group installs it.
   Unit: `plasmalogin.service`; binary `/usr/bin/plasmalogin`; greeter
   `/usr/libexec/plasma-login-greeter`. Config: `/etc/plasmalogin.conf`
   (all keys commented out; sections `Autologin`, `General`, `Users`, `Wayland`, `X11`),
   `/etc/plasmalogin.conf.d/`, vendor defaults `/usr/lib/plasmalogin/defaults.conf`
   and `/usr/lib/plasmalogin/plasmalogin.conf.d/`. PAM: `/usr/lib/pam.d/plasmalogin`
   (substack `password-auth`). Section `[Users]` has `DefaultPath`, `RememberLastSession`,
   `RememberLastUser`, `ReuseSession`. There is no `MaximumUid`/`HideUsers`
   key in the package: a text scan of the packaged binaries and plugins found only
   `UserModel` in the greeter and in `kcm_plasmalogin.so`. The user-list control
   is UNKNOWN: not found by string scan (compressed QML/qrc data can hide keys),
   needs a VM check. The sddm "no user list" setting (`MaximumUid=999`) has no
   known equivalent. Task 10 must find the control on a running VM.
   Task 10 read the shipped files: `plasma-login-manager-6.8.2-1.fc45` has
   `/etc/plasmalogin.conf` (all commented, no user-list key) and an empty
   `/etc/plasmalogin.conf.d/`; `kde-settings-plasmalogin-44.0-1.fc45` has
   `/usr/lib/plasmalogin/defaults.conf` with `[Greeter] WallpaperPlugin=org.kde.image` and
   `[Greeter][Wallpaper][org.kde.image][General] Image=`/`PreviewImage=`. `desktop_plasmalogin`
   writes the background (same group syntax) to `/etc/plasmalogin.conf.d/90-mld.conf`.
   The user list on Fedora KDE stays an open item for the live check (Task 15).
   `kde-settings-sddm-44.0-1.fc45` is the sddm variant (`Theme.Current=01-breeze-fedora`).
   GNOME: `gdm-1:51.1.1-1.fc45` (group `gnome-desktop`, unit `gdm.service`).
3. ildap (`ILDAP_PKG=samba-ldb-ldap-modules`): `samba-ldb-ldap-modules-2:4.25.1-1.fc45.x86_64`
   owns `/usr/lib64/samba/ldb/ildap.so`. `samba-dc-2:4.25.1-1.fc45` owns
   `/usr/lib64/samba/ldb/samba_dsdb.so` (not needed for the ildap bind problem).
   `samba-gpupdate-2:4.25.1-1.fc45.noarch` owns `/usr/bin/samba-gpupdate`;
   `python3-samba` owns `samba/gp/gpclass.py` and `gp_firefox_ext.py`.
4. Firefox (`firefox-160.0-1.fc45.x86_64`, Fedora package, no epoch). The package owns
   `/usr/lib64/firefox/distribution/` (with `distribution.ini`) and `/etc/firefox/`
   with `/etc/firefox/pref`. It ships no `policies.json` and does not own
   `/etc/firefox/policies`. `FIREFOX_POLICY_DIR=/usr/lib64/firefox/distribution`
   (the install-dir location). Whether the build reads `/etc/firefox/policies/policies.json`
   (the path `gp_firefox_ext` writes) is not shown by the package: check on the VM.
5. dnf automatic (`dnf5-plugin-automatic-5.4.7.0-1.fc45.x86_64`). Units
   `dnf5-automatic.timer` and `dnf5-automatic.service` (`ExecStart=/usr/bin/dnf5 automatic --timer`);
   `dnf-automatic.{timer,service}` are symlinks to them. Timer: `OnCalendar=*-*-* 6:00`,
   `RandomizedDelaySec=60m`, `Persistent=true`. Config: `/etc/dnf/automatic.conf` (see item 9;
   `/etc/dnf/dnf5-plugins/automatic.conf` is deprecated), defaults in `/usr/share/dnf5/dnf5-plugins/automatic.conf`:
   `apply_updates = no`, `download_updates = yes`, `reboot = never`, `emit_via = stdio`.
6. authselect (`authselect-libs-1.8.0-1.fc45.x86_64`): profile `sssd` is in
   `/usr/share/authselect/default/sssd/` (`system-auth`, `password-auth`, `postlogin`,
   `fingerprint-auth`, `smartcard-auth`, `nsswitch.conf`, `dconf-db`, `dconf-locks`,
   `README`, `REQUIREMENTS`, `switchable-auth`). `system-auth` and `password-auth`
   are saved as `tests/fixtures/authselect-system-auth` and
   `tests/fixtures/authselect-password-auth`. They are profile templates
   (with `{imply ...}` and `{include if ...}` directives), not rendered PAM files.
7. Other owners (full list: `tests/fedora-probe.sh` output). `pam_mount.so`: `pam_mount-2.20-8.fc45`.
   `cifs.upcall`: `cifs-utils-7.9-2.fc45` (`/usr/bin/cifs.upcall`). `net`: `samba-common-tools-2:4.25.1-1.fc45`.
   `tpm2_ptool`: `tpm2-pkcs11-tools-1.10.1-1.fc45`; `libtpm2_pkcs11.so`: `tpm2-pkcs11-1.10.1-1.fc45`
   (`/usr/lib64/pkcs11/`). `p11-kit-trust.so`: `p11-kit-trust-0.26.5-1.fc45`.
   `linuxx64.efi.stub`: `systemd-boot-unsigned-262.1-1.fc45` (`/usr/lib/systemd/boot/efi/`);
   `ukify`: `systemd-ukify-262.1-1.fc45`. `sbsign`: `sbsigntools-0.9.5-16.fc45`.
   `plymouth-set-default-theme`: `plymouth-scripts-26.134.222-6.fc45`; spinner theme:
   `plymouth-theme-spinner`. `realm`, `adcli`: `/usr/bin` (merged bin). Not in
   Fedora: `google-chrome-stable` (Google repository), `snx-rs` (upstream repository).
8. Package map (Ubuntu to Fedora): `libnss-sss` and `libpam-sss` to `sssd-client`;
   `samba-common-bin` to `samba-common-tools`; `krb5-user` to `krb5-workstation`;
   `libpam-mount` to `pam_mount`; `bind9-host` to `bind-utils`; `libfido2-1` to `libfido2`
   and `fido2-tools`; `sbsigntool` to `sbsigntools`; `systemd-boot-efi` to `systemd-boot-unsigned`;
   `ldap-utils` to `openldap-clients`; `libsasl2-modules-gssapi-mit` to `cyrus-sasl-gssapi`;
   `libtpm2-pkcs11-1` to `tpm2-pkcs11`; `libtpm2-pkcs11-tools` to `tpm2-pkcs11-tools`;
   `libnss3-tools` to `nss-tools`; `p11-kit-modules` to `p11-kit-trust`;
   `samba-dsdb-modules` to `samba-ldb-ldap-modules`; `unattended-upgrades` to `dnf5-plugin-automatic`;
   `sddm-theme-breeze` to `sddm-breeze`; same name: `sssd`, `sssd-tools`, `sssd-ad`, `realmd`,
   `adcli`, `cifs-utils`, `keyutils`, `tpm2-tools`, `mokutil`, `efibootmgr`, `tpm2-openssl`,
   `python3-impacket`, `certmonger`, `opensc`, `curl`, `qemu-guest-agent`, `python3-samba`,
   `plymouth`, `plymouth-theme-spinner`, `firefox`. Desktop: group `workstation-product-environment`
   (GNOME) and `kde-desktop-environment` (KDE).
9. Final review fixes (same cached repodata, 2026-11-12). SELinux (`selinux-policy-targeted-45.24-1.fc45`,
   module `virt_supplementary`): type `virt_qemu_ga_unconfined_exec_t`, domain `virt_qemu_ga_unconfined_t`
   (`unconfined_domain_type`), boolean `virt_qemu_ga_run_unconfined` (default false) with
   `typetransition virt_qemu_ga_t virt_qemu_ga_unconfined_exec_t process virt_qemu_ga_unconfined_t`.
   Stock file contexts use this type only for the fsfreeze hook directories. `qemu-guest-agent.service`
   has `UMask=0077`. Result (ruling R21): the guest snippets on Fedora run through
   `/usr/libexec/mld/qemu-ga-run` with that type and the boolean on. `cert_t` is in `cert_type`
   (module `miscfiles`); module `certmonger` allows `certmonger_t` to create and write `cert_type` files and
   directories and to use `tpm_device_t`. Result: `/etc/tpm2_pkcs11` and `/etc/mld/pki` get `cert_t`.
   `semodule_package` is in `policycoreutils-3.11-2.fc45` (no `semodule-utils` in Fedora 45);
   `ausearch` is in `audit-4.2.1-2.fc45`. Correction to item 5: dnf5-automatic(8) reads
   `/usr/share/dnf5/dnf5-plugins/automatic.conf`, then the host overrides in `/etc/dnf/automatic.conf`;
   the plugin warns that `/etc/dnf/dnf5-plugins/automatic.conf` is a deprecated location. Both `/etc`
   files are not in the payload (ghost files). `dconf-51.0-1.fc45` owns `/etc/dconf/profile/user`
   (`user-db:user`, `system-db:local`, `system-db:site`, `system-db:distro`). The Firefox launcher is
   `/usr/share/applications/org.mozilla.firefox.desktop`. `fedora-workstation-repositories-45-3.fc45`
   (default in the groups `workstation-product` and `kde-desktop`) has
   `/usr/share/dnf5/repos.d/google-chrome.repo` (id `google-chrome`, `enabled=0`) and
   `/etc/default/google-chrome` with `repo_add_once="false"`. `dnf config-manager` is in `dnf5-plugins`.

## Done criteria (designer's call, user may override)

Render tests (`./build.sh client iso` in a `$TMPDIR` copy) for both distros,
plus `bash -n`, `py_compile`, `xmllint`. Then three live builds, each with a
clean `client verify`:

1. GNOME, `UKI=1`, `UKI_TRUST=mok`, `CIFS_HOME=1`, `SNX_RS=1`, `PKI_ENROLL=web`.
2. KDE, `UKI=0`, `CIFS_HOME=0`, `PKI_ENROLL=dcom`.
3. Build 1 again with `UKI_TRUST=db`.

`hw-iso`: render test only, same status as the Ubuntu `hw-iso`. The Ubuntu
client: one render test plus `client verify` on the existing client after
`client resume`, to show no regression.

## Left to the builder

- Exact kickstart layout (autopart vs explicit partitions), as long as ESP
  ≥ 1 GB, `/boot` plain, LUKS2 with the passphrase in keyslot 0, LVM root.
- How `install.list` expresses distro-specific files.
- Name and shape of the SELinux policy module, and which items need one.
- How the Fedora ISO is remastered (`mkksiso` or xorriso).
- Docs: which docs/ pages get Fedora sections; CLAUDE.md Gotchas entries
  for each confirmed Fedora fact.

## Unverified facts in this document

Marked by the source: package names other than `samba-gpupdate`,
`python3-impacket` and the snx-rs repo; dnf5-automatic unit names; Firefox
policy path; kernel-install hook semantics; SELinux items; whether the
dracut networkd DNS problem exists on Fedora. All come from general Fedora
knowledge, not from a check in this session.
