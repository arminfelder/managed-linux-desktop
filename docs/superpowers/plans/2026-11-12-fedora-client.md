# Fedora Client Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `CLIENT_DISTRO=fedora` builds a Fedora 45 client with full parity to the Ubuntu client, SELinux enforcing; `CLIENT_DISTRO=ubuntu` (default) behaves exactly as today.

**Architecture:** One `client/mld` tree. A sourced distro layer (`client/mld/distro.sh`) gives package, repo and path helpers; topic `phase.sh` files branch on `$CLIENT_DISTRO` only where the work differs. The host side gets a kickstart template and a Fedora remaster path next to the subiquity path. A host-side render test (`tests/render-test.sh`) is the automated test for every task; live VM builds (user runs them with `!`) close the work.

**Tech Stack:** bash, Python 3 (render, hw-iso), Anaconda kickstart, dnf5, authselect, SELinux (semanage, checkmodule), dracut, systemd, libvirt/virt-install, xorriso.

**Spec:** `docs/superpowers/specs/2026-11-12-fedora-client-design.md` (read it before Task 1).

## Global Constraints

- Default `CLIENT_DISTRO=ubuntu`. A `lab.env` without `CLIENT_DISTRO` produces the same CIDATA and ISO as before this work (Task 2 baseline).
- Fedora release: 45. Install medium: Fedora Everything netinstall (`Fedora-Everything-netinst-x86_64-45-*.iso`).
- SELinux `enforcing` on Fedora. Never `setenforce 0`, `permissive`, `semanage permissive`, or `selinux --permissive`.
- Lab scripts and `mld-*` units run unconfined (`unconfined_service_t`). Fixes only where a confined stock domain is denied: file contexts, booleans, one module `mld` (`client/mld/selinux/mld.te`). No new confined domains.
- Upstream AVC denials not caused by the lab: ignore list `client/mld/selinux/avc-ignore.list` (one line: `<regex> <Fedora bug URL>`), never a policy module.
- Fedora GNOME is stock: no dock extension, no desktop icons, no `mld-desktop` user unit. Pins go to `org.gnome.shell favorite-apps` (dconf default).
- Patch updates only. No `dnf system-upgrade` code.
- Third-party repo keys pinned in the repo (fingerprint in a comment), as `client/mld/vpn/snx-rs.sources` does today.
- Topic names must not be `pki` or `sb` (CLAUDE.md). New topic: `selinux`.
- Comments: ASD-STE100 style (CLAUDE.md "Code comments"); no comment that restates code.
- Checks per CLAUDE.md: `bash -n` on all shell files, `python3 -m py_compile lib/*.py client/mld/cert/*.py`, `xmllint --noout` on rendered XML.
- `virsh` does not work in the sandbox. Live steps are for the user (`! ./build.sh …`).
- Work on branch `fedora-client` (created in Task 0). Commit only at the commit steps.

## Review Focus

1. Secrets with kickstart-special characters (`"`, `\`, `$`, `#`, space) in `LUKS_PASSPHRASE` / admin hash must arrive unchanged in `ks.cfg` → test `ks_secret_roundtrip` in Task 5.
2. An existing Ubuntu `lab.env` (no `CLIENT_DISTRO`) must render byte-identical `user-data` and the same CIDATA file list → test `ubuntu_baseline_unchanged` in Task 2, re-run in every task.
3. `client resume` against a VM of the other distro must stop before it pushes files → test `resume_distro_mismatch` in Task 3 (host function with stubbed guest answer).
4. A Fedora kernel update with `UKI=1` must give a new UKI + boot entry, a kernel removal must delete them → live check L4 in Task 15.
5. dnf5-automatic must not run while `mld-firstboot` runs, and the night reboot must use `dnf needs-restarting -r` → render test `reboot_rule_fedora` in Task 11 + live check L5 in Task 15.

---

### Task 0: Branch

- [ ] **Step 1:** `git switch -c fedora-client` (repo is on `main`, untracked `CLAUDE.md` stays untracked).

---

### Task 1: Probe Fedora 45 facts (blockers)

Answers the spec "First task: blockers" without a VM, in a container (the sandbox allows `/var/run/docker.sock`).

**Files:**
- Create: `tests/fedora-probe.sh`
- Modify: `docs/superpowers/specs/2026-11-12-fedora-client-design.md` (new section "Probe results 2026-MM-DD")

**Interfaces:**
- Produces (recorded in the spec, used by Tasks 4–12): `QEMU_GA_FILTER` (content of `/etc/sysconfig/qemu-ga`), `KDE_DM` (`sddm` or `plasmalogin`, and its unit name), `ILDAP_PKG` (package that owns `ldb/modules/ildap.so` or the same module), `FIREFOX_POLICY_DIR`, `DNF_AUTOMATIC_UNITS` (timer + service names, config path), Fedora package names for every Ubuntu package in `client/user-data.tmpl:40-73` and in `pkg_install` calls (`grep -rn pkg_install client/mld`).

- [ ] **Step 1: Write `tests/fedora-probe.sh`.** Runs `docker run --rm registry.fedoraproject.org/fedora:45 bash -c '…'` with: `dnf -q install -y qemu-guest-agent && cat /etc/sysconfig/qemu-ga`; `dnf group info kde-desktop-environment workstation-product-environment`; `dnf repoquery --whatprovides '*/ldb/modules/ldb/ildap.so' '*/ldb/ildap.so'`; `dnf repoquery -l firefox | grep -E 'policies|distribution'`; `dnf repoquery -l dnf5-plugin-automatic | grep -E 'systemd|\.conf'`; `dnf repoquery --whatprovides` for each Ubuntu file/command that the map needs (`pam_mount.so`, `cifs.upcall`, `net`, `tpm2_ptool`, `libtpm2_pkcs11.so`, `p11-kit-trust.so`, `linuxx64.efi.stub`, `sbsign`, `mokutil`, `certutil`, `pkcs11-tool`, `ldapsearch`, `fido2-token`, `plymouth-set-default-theme`, spinner theme). Prints `KEY=VALUE` and a TSV `ubuntu_pkg<TAB>fedora_pkg`.
- [ ] **Step 2: Run it.** `bash tests/fedora-probe.sh | tee "$TMPDIR/probe.txt"` Expected: every map line has a Fedora package; no line `MISSING`.
- [ ] **Step 3: Decide the blockers and record them in the spec.**
  - If `qemu-ga` filters `guest-exec`/`guest-file-*`: the kickstart `%post` (Task 5) writes `/etc/sysconfig/qemu-ga` with those RPCs allowed and a comment that names the reason. Record it in the spec as a security fact.
  - If `KDE_DM=plasmalogin`: Task 10 uses its config instead of `desktop_sddm`; record the config file and the "no user list" key from the package files (`dnf repoquery -l`).
  - If no package gives `ildap`: stop. Report to the user (spec anti-goal: no silent skip).
- [ ] **Step 4: Commit** `git add tests/fedora-probe.sh docs/superpowers/specs/ && git commit -m "fedora: probe Fedora 45 package facts"`

---

### Task 2: Render test harness + Ubuntu baseline

**Files:**
- Create: `tests/render-test.sh`, `tests/README.md` (5 lines: what it does, how to run)

**Interfaces:**
- Produces: `tests/render-test.sh [ubuntu|fedora|all] [TEST...]`. Copies the work tree (`git ls-files` + untracked non-ignored files) to `$TMPDIR/mld-render.XXXX`, writes a `lab.env` from `env.example` with test secrets, replaces `guest-exec.sh` in the copy with a stub that prints `base64("ODJ-TEST-BLOB")` for `odj-provision.ps1` and `ID=$STUB_OS_ID` for os-release queries, builds fake ISOs with `xorriso` (Ubuntu: `/boot/grub/grub.cfg` with a `linux /casper/vmlinuz ---` line; Fedora: `/EFI/BOOT/grub.cfg` and `/boot/grub2/grub.cfg` with `linuxefi /images/pxeboot/vmlinuz inst.stage2=hd:LABEL=Fedora-E-dvd-x86_64-45 quiet` and volume ID `Fedora-E-dvd-x86_64-45`), runs `./build.sh client iso`, then runs named test functions. Helpers: `t_ok NAME`, `t_fail NAME MSG`, `iso_ls ISO`, `iso_cat ISO PATH`. Exit 1 on any failure.
- Test functions live in the same file, one per name used in this plan.

- [ ] **Step 1: Write test `ubuntu_baseline_unchanged`.** Before any product change, `tests/render-test.sh --record-baseline` stores in `tests/baseline/ubuntu/`: rendered `user-data` (secrets replaced by fixed test values, `instance-id` line removed), `iso_ls cidata.iso` sorted, and the patched `grub.cfg`. The test compares a fresh render with these files (`diff -u`).
- [ ] **Step 2: Run** `tests/render-test.sh --record-baseline && tests/render-test.sh ubuntu ubuntu_baseline_unchanged` Expected: `ok ubuntu_baseline_unchanged`.
- [ ] **Step 3: Run** the CLAUDE.md checks: `bash -n` on all `*.sh` + `tests/*.sh`. Expected: no output.
- [ ] **Step 4: Commit** `git add tests/ && git commit -m "tests: host render test with Ubuntu baseline"`

---

### Task 3: `CLIENT_DISTRO` setting, media, derived values, mismatch guard

**Files:**
- Modify: `env.example` (new `CLIENT_DISTRO`, `FEDORA_ISO`, `FEDORA_URL`, `FEDORA_SUMS_URL` next to `UBUNTU_*` lines 14–21; help text in the house style), `lib/settings.sh:14-23` (`S_CHOICES[CLIENT_DISTRO]="ubuntu fedora"`; `S_WHEN` for `FEDORA_*` = `[ "${CLIENT_DISTRO:-ubuntu}" = fedora ]`, for `UBUNTU_*` = the opposite), `lib/config.sh:20-36`, `lib/common.sh:10` (`media_files`), `lib/host.sh:59` (`cmd_fetch`), `build.sh:171`, `lib/client.sh` (`client_resume`), `client/guest/` (new `os-id.sh`)
- Test: `tests/render-test.sh`

**Interfaces:**
- Produces (exported from `lib/config.sh`): `CLIENT_DISTRO` (`ubuntu|fedora`), `CLIENT_ISO` (= `$UBUNTU_ISO` or `$FEDORA_ISO`), `CLIENT_INSTALL_ISO` (= `$STAGE/ubuntu-autoinstall.iso` or `$STAGE/fedora-ks.iso`), `CLIENT_DESKTOP`, `CLIENT_DM` (package/group names per distro + DE), `CLIENT_DM_UNIT` (`gdm.service`, `sddm.service` or the Task 1 `KDE_DM` unit), `CLIENT_OS_VARIANTS` (space list for `pick_os_variant`: Fedora `fedora45 fedora44 fedora-unknown linux2024 linux2022`).
- Produces: `client_check_distro` in `lib/client.sh`: runs `guest_run client client/guest/os-id.sh` (prints `ID` from `/etc/os-release`), dies with `"$CLIENT_VM runs <id>, lab.env has CLIENT_DISTRO=<d>: build the client again"` on mismatch. Called first in `client_resume`.
- `config.env` (CIDATA, `client_iso` loop at `lib/client.sh:150`) and the `client_resume` value list (`lib/client.sh:395`) gain `CLIENT_DISTRO`.
- `media_files` prints `$WINSERVER_ISO $VIRTIO_ISO $CLIENT_ISO`. Fedora sums: `verify_media` keeps the `checksums.sha256` model; `cmd_fetch` for Fedora also fetches `FEDORA_SUMS_URL` (Fedora `CHECKSUM` file) and `gpgv`-checks it only if `fedora.gpg` exists in `MEDIA_DIR` — else `NO-SUM` as for Windows, user runs `pin`.

- [ ] **Step 1: Write tests** `distro_default_ubuntu` (lab.env without the line → `CLIENT_DISTRO=ubuntu` in `cidata/mld/config.env`), `distro_fedora_config` (with `CLIENT_DISTRO=fedora` → `config.env` has `CLIENT_DISTRO=fedora`, `CLIENT_DM_UNIT` is `gdm.service` for gnome), `distro_invalid` (`CLIENT_DISTRO=arch` → `build.sh` exits ≠ 0 and stderr has `CLIENT_DISTRO must be ubuntu or fedora`), `resume_distro_mismatch` (`STUB_OS_ID=ubuntu`, `CLIENT_DISTRO=fedora`, run `./build.sh client resume` with the stub → exit ≠ 0, stderr has `build the client again`, the stub log has no `install -D` call).
- [ ] **Step 2: Run** `tests/render-test.sh all distro_default_ubuntu distro_fedora_config distro_invalid resume_distro_mismatch` Expected: FAIL (`CLIENT_DISTRO` unknown).
- [ ] **Step 3: Implement** the derivations in `lib/config.sh` as a `case "$CLIENT_DISTRO/$CLIENT_DE"` next to the existing `case "$CLIENT_DE"` (lines 29–33), the settings, `media_files`, `cmd_fetch`, `client_check_distro`, `os-id.sh`. `client iso` for Fedora may still die with `"fedora: kickstart not implemented"` until Task 5.
- [ ] **Step 4: Run** the four tests + `ubuntu_baseline_unchanged`. Expected: all `ok`.
- [ ] **Step 5: Commit** `git commit -am "client: CLIENT_DISTRO setting (ubuntu|fedora)"` (add new files first).

---

### Task 4: Distro layer on the client + per-distro install.list

**Files:**
- Create: `client/mld/distro.sh`
- Modify: `client/mld/firstboot.sh:40-45` (remove `pkg_install`; source `distro.sh` before the topic loop at line 48), `client/mld/install.list` (4th column), `lib/client.sh:5` (`install_list`), `lib/client.sh:142` (CIDATA gets the filtered list, not `cp client/mld/install.list`), `client/user-data.tmpl` (no change needed: it reads 3 columns of the filtered list)
- Test: `tests/render-test.sh`

**Interfaces:**
- `client/mld/distro.sh` (sourced, needs `CLIENT_DISTRO` from `config.env`; default `ubuntu`) defines:
  - `pkg_installed PKG` → exit 0 if installed (`dpkg -s` / `rpm -q`)
  - `pkg_install PKG...` → installs the missing ones in one call (`apt-get install -y` with `DEBIAN_FRONTEND=noninteractive` / `dnf -y install`)
  - `pkg_purge PKG...` → removes installed ones (`apt-get purge -y` / `dnf -y remove`)
  - `pkg_version PKG` → prints version or nothing
  - `pkg_refresh` → `apt-get update` / `dnf -q makecache`
  - `initrd_path KVER` → `/boot/initrd.img-KVER` / `/boot/initramfs-KVER.img`
  - variables: `SHIM_EFI` (`\EFI\ubuntu\shimx64.efi` / `\EFI\fedora\shimx64.efi`), `SHIM_FILE` (`/boot/efi/EFI/<d>/shimx64.efi`), `BOOT_LABEL_RE` (`ubuntu` / `fedora`), `PKCS11_DIR` (`/usr/lib/x86_64-linux-gnu/pkcs11` / `/usr/lib64/pkcs11`), `PAM_AUTH_FILES` (`/etc/pam.d/common-auth` / `/etc/pam.d/system-auth /etc/pam.d/password-auth`), `PAM_SESSION_FILES` (`/etc/pam.d/common-session` / same two Fedora files).
  - `distro.sh` is also copied for host-side guest snippets: `client/guest/verify-facts.sh` sources `/etc/mld/distro.sh`.
- `install.list` 4th column: `all|ubuntu|fedora` (missing = `all`). `install_list` (host) prints `src dst mode` only for `all` and `$CLIENT_DISTRO`. Rows: `distro.sh - 644 all`; Ubuntu-only now: `boot/uki-postinst.sh`, `boot/uki-postrm.sh`, `apps/mozilla.*`, `apps/google-chrome.sources`, `vpn/snx-rs.sources`, `update/52mld-unattended-upgrades`; `desktop/mld-desktop.service` + `desktop/desktop.sh` stay `all` (KDE uses them; Task 10 skips enabling on Fedora GNOME).

- [ ] **Step 1: Write tests** `installlist_filter` (Fedora CIDATA has `mld/distro.sh`, has no `mld/apps/mozilla.sources`; its `mld/install.list` has 3 columns on each line; Ubuntu CIDATA list equals the baseline plus `distro.sh`) and `distro_sh_functions` (source `client/mld/distro.sh` with `CLIENT_DISTRO=fedora` in a subshell; `initrd_path 6.17.1-300.fc45.x86_64` = `/boot/initramfs-6.17.1-300.fc45.x86_64.img`; `SHIM_EFI` = `\EFI\fedora\shimx64.efi`; with `ubuntu`: `/boot/initrd.img-…`, `\EFI\ubuntu\shimx64.efi`).
- [ ] **Step 2: Run** them. Expected: FAIL.
- [ ] **Step 3: Implement.** Update the Ubuntu baseline file list once (`--record-baseline`) only for the added `distro.sh`; say so in the commit message.
- [ ] **Step 4: Run** both + `ubuntu_baseline_unchanged`. Expected: `ok`.
- [ ] **Step 5: Commit** `git commit -m "client: distro layer and per-distro install list"`

---

### Task 5: Kickstart + Fedora ISO remaster + `client vm`

**Files:**
- Create: `client/ks.cfg.tmpl`
- Modify: `lib/config.sh` (`render` gets mode `ks`), `lib/client.sh:130-184` (`client_iso`: branch per distro; split today's body into `client_iso_ubuntu_remaster` and new `client_iso_fedora_remaster`), `lib/client.sh:193-238` (`client_vm`: `--cdrom "$CLIENT_INSTALL_ISO"`, `pick_os_variant $CLIENT_OS_VARIANTS`)
- Test: `tests/render-test.sh`

**Interfaces:**
- `render SRC DST ks`: escapes `\` → `\\` and `"` → `\"`; the template puts each secret in double quotes. Values with a newline fail the render (`die`).
- `client/ks.cfg.tmpl` content (same facts as `client/user-data.tmpl`): `text`, `lang en_US.UTF-8`, `keyboard us`, `timezone @@GUEST_TZ@@ --utc`, `url --mirrorlist=…repo=fedora-45&arch=x86_64`, `repo --name=updates --mirrorlist=…repo=updates-released-f45&arch=x86_64`, `network --bootproto=dhcp --device=link --hostname=@@CLIENT_HOSTNAME@@ --nameserver=@@DC_IP@@`, `selinux --enforcing`, `rootpw --lock`, `user --name=@@CLIENT_ADMIN@@ --groups=wheel --iscrypted --password="@@CLIENT_ADMIN_HASH@@"`, `services --enabled=sshd,qemu-guest-agent,mld-firstboot`, storage: `zerombr`, `clearpart --all --initlabel`, `part /boot/efi --fstype=efi --size=1024`, `part /boot --fstype=ext4 --size=1024`, `part pv.01 --grow --encrypted --luks-version=luks2 --passphrase="@@LUKS_PASSPHRASE@@"`, `volgroup vg0 pv.01`, `logvol / --vgname=vg0 --name=root --fstype=xfs --grow --size=8192`; `%packages` = `@@CLIENT_DESKTOP@@` + the Task 1 Fedora map of `user-data.tmpl:40-73` + `policycoreutils-python-utils checkpolicy`; `%post --nochroot` copies CIDATA `mld/` to `/mnt/sysroot/etc/mld` with the same modes as `user-data.tmpl:75-81`; `%post` runs the `install.list` loop of `user-data.tmpl:83-87`, `restorecon -R /etc/mld /usr/local /etc/systemd`, `grubby --update-kernel=ALL --args="console=tty0 console=ttyS0,115200n8"`, the `qemu-ga` RPC change from Task 1 (only if needed), `/usr/local/sbin/mld-uki all`; last line `reboot`.
- `client_iso_fedora_remaster`: extract `/EFI/BOOT/grub.cfg` and `/boot/grub2/grub.cfg`, set `timeout=1`, add ` inst.ks=hd:LABEL=CIDATA:/ks.cfg inst.text console=ttyS0,115200n8` to each `linuxefi|linux … /images/pxeboot/vmlinuz` line, die `"no images/pxeboot/vmlinuz entry in grub.cfg: the ISO layout changed"` if none, write `$STAGE/fedora-ks.iso` with `-boot_image any replay` (shim/grub stay signed). CIDATA gets `ks.cfg` at its root; no `user-data`/`meta-data` for Fedora.

- [ ] **Step 1: Write tests** `ks_render` (Fedora CIDATA has `/ks.cfg`; `grep -c '^selinux --enforcing$'` = 1; has `--luks-version=luks2`; no `@@`), `ks_secret_roundtrip` (lab.env `LUKS_PASSPHRASE='a"b\c$d #e'`; python `shlex.split` of the `part pv.01` line gives `--passphrase=a"b\c$d #e`), `ks_newline_rejected` (secret with `\n` → `client iso` exits ≠ 0), `fedora_grub_patched` (both grub.cfg files in `fedora-ks.iso` have `inst.ks=hd:LABEL=CIDATA:/ks.cfg`), `ks_validate` (if `ksvalidator` from `pykickstart` exists on the host or in a `fedora:45` container: `ksvalidator -v F45 ks.cfg` exit 0; else skip with `skip ks_validate`).
- [ ] **Step 2: Run** them. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** them + `ubuntu_baseline_unchanged`. Expected: `ok`.
- [ ] **Step 5: Commit** `git commit -m "client: Fedora kickstart install and ISO remaster"`

---

### Task 6: Boot topic on Fedora (dracut, UKI hooks, shim, admin password)

**Files:**
- Create: `client/mld/boot/60-mld-uki.install` (kernel-install plugin; `install.list` row → `/etc/kernel/install.d/60-mld-uki.install 755 fedora`)
- Modify: `client/mld/boot/phase.sh` (use `initrd_path`; `phase_admin_pw`: on Fedora only check `passwd -S` = `P`, fail `"admin has no password"` else), `client/mld/boot/uki.sh:106-107` (`$SHIM_EFI`, `$SHIM_FILE`; source `/etc/mld/distro.sh`), `client/guest/grub-entry.sh:4` (`$BOOT_LABEL_RE`; source distro.sh), `lib/tests.sh:199` (message names the label), `client/guest/verify-facts.sh:65` (`initrd_path`)
- Test: `tests/render-test.sh`

**Interfaces:**
- `60-mld-uki.install COMMAND KVER [ENTRY_DIR KERNEL_IMAGE…]`: `add` → `exec /usr/local/sbin/mld-uki "$KVER"`; `remove` → `exec /usr/local/sbin/mld-uki remove "$KVER"`; other commands → exit 0. Must run after `50-dracut.install` (name order: `60-`).
- `write_dracut_conf` keeps the network-module omit list; whether the networkd DNS mask is needed on Fedora is decided in Task 15 (live), not here.

- [ ] **Step 1: Write tests** `kernel_install_hook` (run the hook in the copy with a stub `mld-uki` on `PATH` that logs its args: `add 6.17.1 /x /y` → log `6.17.1`; `remove 6.17.1` → `remove 6.17.1`; `inspect` → no log, exit 0) and `fedora_paths_used` (`grep -n 'EFI/ubuntu\|initrd.img-' client/mld client/guest -r` finds only `distro.sh`).
- [ ] **Step 2: Run** them. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** them + `ubuntu_baseline_unchanged`. Expected: `ok`.
- [ ] **Step 5: Commit** `git commit -m "boot: Fedora kernel-install hook, shim path, initrd path"`

---

### Task 7: Identity and home on Fedora (DNS, authselect, mkhomedir)

**Files:**
- Modify: `client/mld/ad/phase.sh:41-60` (`phase_dns`), `client/mld/ad/phase.sh:85-120` (PAM checks use `$PAM_AUTH_FILES`/`$PAM_SESSION_FILES`), `client/mld/home/phase.sh:9-30`
- Test: `tests/render-test.sh`

**Interfaces:**
- `pam_enable_mount` / `pam_disable_mount` / `pam_enable_mkhomedir` in `client/mld/home/phase.sh`. Ubuntu bodies = today's `pam-auth-update` lines. Fedora:
  - `pam_enable_mount`: if `/etc/authselect/custom/mld` is missing, `authselect create-profile mld -b sssd`; insert `auth optional pam_mount.so` after the `pam_sss.so` auth line and `session optional pam_mount.so` after the `pam_sss.so` session line in `/etc/authselect/custom/mld/{system-auth,password-auth}`, only if `pam_mount.so` is not there yet; `authselect select custom/mld --force`.
  - `pam_disable_mount` + `pam_enable_mkhomedir`: `authselect select sssd with-mkhomedir --force`; `pkg_install oddjob-mkhomedir`; `systemctl enable --now oddjobd.service`.
- `phase_dns` on Fedora: write `/etc/NetworkManager/conf.d/90-mld-dns.conf` with the same `dns=none` + `systemd-resolved=false` content as Ubuntu, set the connection `ipv4.ignore-auto-dns yes ipv4.dns $DC_IP ipv4.dns-search $DOMAIN` with `nmcli` on the active connection of the NIC, then `resolvectl revert`. No `/etc/systemd/network` mask unless Task 15 shows `zzzz-dracut-default.network`.

- [ ] **Step 1: Write test** `authselect_profile_edit`: in the copy, a fake `/etc/authselect/custom/mld/system-auth` (fixture `tests/fixtures/authselect-system-auth`, the Fedora 45 sssd profile file from the Task 1 container: `authselect create-profile` then `cat`) and a `authselect` stub; call `pam_enable_mount` with `ROOT=$tmp` path prefix; expect one `pam_mount.so` auth line directly after `pam_sss.so` auth, one session line after `pam_sss.so` session; a second call changes nothing (`cmp`). This needs `pam_enable_mount` to use `${AUTHSELECT_DIR:-/etc/authselect}`.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** it + `ubuntu_baseline_unchanged`. Expected: `ok`.
- [ ] **Step 5: Commit** `git commit -m "ad, home: Fedora DNS and authselect profile with pam_mount"`

---

### Task 8: SELinux topic

**Files:**
- Create: `client/mld/selinux/phase.sh`, `client/mld/selinux/mld.te`, `client/mld/selinux/fcontexts.list`, `client/mld/selinux/booleans.list`, `client/mld/selinux/avc-ignore.list` (install.list rows, all `- 644 fedora`)
- Modify: `client/mld/firstboot.sh:48` (topic loop: `selinux` only when the file exists), `client/mld/firstboot.sh` `main` (call `phase_selinux` on Fedora directly after `phase_admin_pw`, and again at the end before `phase_cleanup` with `restorecon` only), `CLAUDE.md` Layout topic list
- Test: `tests/render-test.sh`

**Interfaces:**
- `phase_selinux`: fails `"SELinux is not enforcing"` if `getenforce` ≠ `Enforcing`; applies `booleans.list` (`name on|off`, `setsebool -P`); applies `fcontexts.list` (`<regex> <type>`, `semanage fcontext -a` or `-m` when present); builds the module only when `sha256sum mld.te` differs from `$STATE/selinux.sha` (`checkmodule -M -m -o … && semodule_package … && semodule -i mld.pp`); `restorecon -R` on every path root in `fcontexts.list`.
- Start values (each line with a comment that names the denial or the reason; Task 15 adds the rest from real AVCs):
  - `booleans.list`: `use_samba_home_dirs on`
  - `fcontexts.list`: `/usr/local/libexec/mld-cm-submit certmonger_unconfined_exec_t`
  - `mld.te`: `module mld 1.0;` with no rules yet.
  - `avc-ignore.list`: empty, header comment with the line format.
- `selinux_avc_report` (in `phase.sh`, used by verify): prints the AVC lines since boot (`ausearch -m AVC,USER_AVC -ts boot -i`) that match no regex in `avc-ignore.list`.

- [ ] **Step 1: Write tests** `selinux_lists_parse` (every non-comment line of `fcontexts.list` has 2 fields and the regex starts with `/`; `booleans.list` value is `on|off`; `avc-ignore.list` lines have a URL as 2nd field) and `selinux_te_compiles` (in a `fedora:45` container: `checkmodule -M -m -o /tmp/mld.mod mld.te` exit 0; skip if docker is missing).
- [ ] **Step 2: Run.** Expected: FAIL (files missing).
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** them + `ubuntu_baseline_unchanged` (Ubuntu CIDATA must not have `mld/selinux/`). Expected: `ok`.
- [ ] **Step 5: Commit** `git commit -m "selinux: Fedora topic with booleans, file contexts, module mld"`

---

### Task 9: Apps, VPN, GPO, PKI paths on Fedora

**Files:**
- Create: `client/mld/apps/google-chrome.repo`, `client/mld/apps/google-linux-signing.asc` (key from `client/mld/apps/google-chrome.sources`, same fingerprint, comment with it), `client/mld/vpn/snx-rs.repo`, `client/mld/vpn/snx-rs.asc` (from `https://ancwrd1.github.io/snx-rs/KEY.gpg`; fingerprint must equal `81EE7E8627CB26ECA46CE6572BE0562851E26770` from `vpn/snx-rs.sources:1`, else stop and ask the user) — install.list rows `- 644 fedora`
- Modify: `client/mld/apps/phase.sh` (Fedora: `rpm --import` the asc, install the repo file only if `/etc/yum.repos.d/google-chrome.repo` is missing, `pkg_install firefox google-chrome-stable`; no Mozilla repo, no pin, no snap check), `client/mld/vpn/phase.sh` (Fedora: repo + key → `/etc/yum.repos.d/snx-rs.repo`, `pkg_install snx-rs`; remove path: `pkg_purge snx-rs`, delete the repo file), `client/mld/gpo/phase.sh:137` (Fedora: `pkg_install samba-gpupdate $ILDAP_PKG` from Task 1), `client/mld/cert/phase.sh:200-201` (package names through a `CERT_PKGS` array per distro, from the Task 1 map), `client/mld/cert/autoenroll.py:304` (module path: first existing of `$PKCS11_DIR/libtpm2_pkcs11.so`, `/usr/lib64/pkcs11/libtpm2_pkcs11.so`, `/usr/lib/x86_64-linux-gnu/pkcs11/libtpm2_pkcs11.so`; no `dpkg -L`)
- Test: `tests/render-test.sh`

**Interfaces:**
- `.repo` files: `gpgcheck=1`, `repo_gpgcheck=0`, `gpgkey=file:///etc/pki/rpm-gpg/mld-<name>.asc` (phase installs the asc there).
- If Task 1 shows Firefox reads a different policy dir than `gp_firefox_ext` writes (`/etc/firefox/policies/policies.json`): `phase_browsers` makes a symlink from the Fedora dir to `/etc/firefox/policies/policies.json`, with a comment.

- [ ] **Step 1: Write tests** `fedora_repo_keys` (`gpg --show-keys --with-colons` of each asc: fingerprint = the value in the comment line of the matching repo file; snx-rs = `81EE7E86…26770`), `no_dpkg_on_fedora_paths` (`grep -rn 'dpkg\|apt-get\|apt-config\|pam-auth-update\|update-alternatives' client/mld client/guest` → each hit is inside an `ubuntu)` branch of a `case "$CLIENT_DISTRO"` or in `distro.sh`; the test greps with `-B3` and checks for `ubuntu)`), `autoenroll_module_path` (`python3 -c` import of the path helper with a temp dir that has only the lib64 path → returns it).
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** them + `ubuntu_baseline_unchanged`. Expected: `ok`.
- [ ] **Step 5: Commit** `git commit -m "apps, vpn, gpo, cert: Fedora repos, pinned keys, package names"`

---

### Task 10: Desktop and branding on Fedora

**Files:**
- Modify: `client/mld/desktop/phase.sh` (Fedora GNOME: write the dconf default `favorite-apps` as today, do not enable `mld-desktop.service`, disable it if enabled; Fedora KDE: today's flow, `desktop_sddm` without the budgie block — or the `KDE_DM=plasmalogin` variant from Task 1 with the same two requirements: no user list, background `/usr/share/mld/brand/background.png`), `client/mld/brand/phase.sh:10-31` (Fedora: `plymouth-set-default-theme mld` instead of `update-alternatives`; keep the hash-gated `dracut --force --regenerate-all` + `mld-uki all`; `initrd_path`)
- Test: `tests/render-test.sh`

- [ ] **Step 1: Write test** `fedora_desktop_rules`: source `desktop/phase.sh` with stubs (`systemctl`, `dconf`, `pkg_install` log their args) and `CLIENT_DISTRO=fedora CLIENT_DE=gnome`, run the pins function → log has no `enable mld-desktop`; dconf file has `favorite-apps=[` with `mld-o365-outlook.desktop`.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** it + `ubuntu_baseline_unchanged`. Expected: `ok`.
- [ ] **Step 5: Commit** `git commit -m "desktop, brand: stock Fedora GNOME, Fedora KDE, Plymouth default"`

---

### Task 11: Patch updates on Fedora

**Files:**
- Create: `client/mld/update/automatic.conf` (→ the Task 1 config path, `644 fedora`), `client/mld/update/dnf-automatic-mld.conf` (drop-in for the Task 1 service unit → `/etc/systemd/system/<unit>.d/mld.conf`, `644 fedora`)
- Modify: `client/mld/update/phase.sh` (Fedora: `pkg_install dnf5-plugin-automatic`, install conf, `systemctl enable --now <timer> mld-reboot.timer`), `client/mld/update/reboot.sh`
- Test: `tests/render-test.sh`

**Interfaces:**
- `automatic.conf`: `[commands] upgrade_type = default`, `apply_updates = yes`, `reboot = never` (mld-reboot owns reboots).
- Drop-in: `[Service] ExecCondition=/bin/sh -c '! systemctl -q is-active mld-firstboot.service'`.
- `reboot.sh` gets `reboot_needed` (Ubuntu: `[ -e /run/reboot-required ]`; Fedora: `! dnf needs-restarting -r >/dev/null`), the busy-unit list per distro (Ubuntu `apt-daily-upgrade.service`, Fedora the Task 1 service), and sources `/etc/mld/distro.sh` (reads `CLIENT_DISTRO` from `/etc/mld/config.env`). The other rules stay.

- [ ] **Step 1: Write test** `reboot_rule_fedora`: run `reboot.sh` with stubs on `PATH` (`dnf` exit 1 for `needs-restarting -r`, `grep` real, `/etc/crypttab` fixture via `CRYPTTAB=` variable, `systemctl is-active mld-firstboot.service` → active) → output `reboot required, but mld-firstboot.service runs`, no `systemctl reboot` call; with `dnf` exit 0 → exit 0 and no output.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement** (`reboot.sh` reads `${CRYPTTAB:-/etc/crypttab}`).
- [ ] **Step 4: Run** it + `ubuntu_baseline_unchanged`. Expected: `ok`.
- [ ] **Step 5: Commit** `git commit -m "update: dnf5-automatic patch updates and Fedora reboot rule"`

---

### Task 12: `client verify` on Fedora

**Files:**
- Modify: `client/guest/verify-facts.sh` (source `/etc/mld/distro.sh`; package facts as `<name>_pkg=installed <version>` or empty, on both distros; Fedora facts: `selinux=$(getenforce)`, `avc_unexpected=<count from selinux_avc_report>`, `authselect=$(authselect current --raw)`, `upd_timer`, `upd_conf` (apply_updates value), `firefox_origin` = `dnf repoquery --installed --qf '%{from_repo}' firefox`; `p11()` + `p11kit_trust` use `$PKCS11_DIR`), `lib/tests.sh:5-110` (checks: package checks match `installed *`; Firefox check per distro: Ubuntu `packages.mozilla.org`, Fedora origin `fedora` or `updates`; update checks per distro; Fedora-only checks "SELinux enforcing", "no unexpected AVC denials", "authselect custom/mld" (CIFS_HOME=1) or "sssd with-mkhomedir" (CIFS_HOME=0); "desktop user unit" check only on Ubuntu or KDE; DM unit from `CLIENT_DM_UNIT`)
- Test: `tests/render-test.sh`

- [ ] **Step 1: Write test** `verify_checks_fedora`: source `lib/tests.sh` in the copy, stub `guest_run`/`client_boot_facts` to print a fixture `tests/fixtures/verify-facts-fedora.txt` (all facts good) → `client_verify` prints no `FAIL` lines for the fact-based checks (stub `client_verify_login`, `client_verify_browsers` to return 0); second fixture with `selinux=Permissive` → a `FAIL  SELinux enforcing` line. Same with `tests/fixtures/verify-facts-ubuntu.txt` (made from the current output format, rewritten to `installed <ver>`) → no `FAIL`.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** it + `ubuntu_baseline_unchanged`. Expected: `ok`.
- [ ] **Step 5: Commit** `git commit -m "verify: Fedora facts and checks, SELinux and authselect"`

---

### Task 13: `client hw-iso` for Fedora

**Files:**
- Create: `lib/hw-ks.py`
- Modify: `lib/client.sh:43-90` (`client_hw_iso`: Fedora branch)
- Test: `tests/render-test.sh`

**Interfaces:**
- `lib/hw-ks.py IN_KS OUT_KS`: drops lines starting with `zerombr`, `clearpart`, `part `, `volgroup`, `logvol`, `user `, `rootpw`, `network ` (Anaconda then asks for storage, user and host name); drops `qemu-guest-agent` from `%packages` and from `services`; sets `CLIENT_TARGET=hw` in the copied `config.env`; the `%post --nochroot` source is `/run/install/repo/mld` (the hardware ISO itself) and the ODJ blob `/run/install/repo/odj/<HOSTNAME>.txt` (host name from `/mnt/sysroot/etc/hostname`). No secrets in the output (same rule as `lib/client.sh:60`).
- The hw ISO puts `ks.cfg`, `mld/`, `odj/` on the Fedora ISO itself; grub lines get `inst.ks=hd:LABEL=<ISO volume ID>:/ks.cfg` without `inst.text` (graphical, so a person can fill the spokes).

- [ ] **Step 1: Write test** `hw_ks_fedora`: `./build.sh client hw-iso` in the copy with `CLIENT_DISTRO=fedora` → `ks.cfg` in `mld-hw.iso` has no `--passphrase`, no `--password`, no `^part `, no `qemu-guest-agent`; has `selinux --enforcing`; grub.cfg has `inst.ks=hd:LABEL=`.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** it + `ubuntu_baseline_unchanged` + `python3 -m py_compile lib/hw-ks.py`. Expected: `ok`.
- [ ] **Step 5: Commit** `git commit -m "client: hw-iso for Fedora (partial kickstart)"`

---

### Task 14: Docs and CLAUDE.md

**Files:**
- Modify: `README.md` (setting `CLIENT_DISTRO`, Fedora media), `docs/boot-and-disk.md`, `docs/identity-and-pki.md`, `docs/desktop-and-apps.md`, `docs/management.md`, `docs/real-hardware.md` (Fedora sections), `CLAUDE.md` (Purpose line, Layout: `distro.sh`, `selinux` topic, `ks.cfg.tmpl`, `tests/`; Checks: `tests/render-test.sh all`; Gotchas: one bullet per Task 1 fact)
- Procedural text (numbered steps) in ASD-STE100: invoke the `asd-ste100` skill first; one note per document that STE was applied. Descriptive sections keep the normal style. Tone: memory `feedback-docs-tone` (factual, for technicians).

- [ ] **Step 1:** Write the docs.
- [ ] **Step 2: Run** `tests/render-test.sh all` (all tests). Expected: all `ok`.
- [ ] **Step 3: Commit** `git commit -m "docs: Fedora client"`

---

### Task 15: Live builds (user runs the libvirt steps)

The implementer prepares each command; the user runs it with `!`. Record each result (pass, or the exact error) in the spec "Probe results" section. Fix each failure in the task that owns the code, with a render test where one is possible, then rebuild.

- [ ] **L1 build 1:** `lab.env`: `CLIENT_DISTRO=fedora CLIENT_DE=gnome UKI=1 UKI_TRUST=mok CIFS_HOME=1 SNX_RS=1 PKI_ENROLL=web ENROLL_TPM2=1`. `! ./build.sh fetch && ./build.sh client destroy --confirm <VM> ; ./build.sh client iso && ./build.sh client vm && ./build.sh client wait && ./build.sh client mok-enroll && ./build.sh client verify` Expected: no `FAIL` line.
- [ ] **L2 SELinux loop:** for each line of `selinux_avc_report`: decide lab-caused (→ `fcontexts.list`, `booleans.list` or an `allow` in `mld.te`, each with a comment) or upstream (→ `avc-ignore.list` with the Fedora bug URL; search bugzilla.redhat.com first, open none yourself — tell the user). `client resume` + `client verify` until `no unexpected AVC denials` is ok.
- [ ] **L3 DNS:** in build 1, `./guest-exec.sh client 'ls /run/systemd/network/'`. If `zzzz-dracut-default.network` exists, add the mask to the Fedora `phase_dns` path (Task 7) and a Gotcha.
- [ ] **L4 kernel update with UKI:** `./guest-exec.sh client 'dnf -y reinstall kernel-core || dnf -y upgrade kernel'`, then `./build.sh client verify` Expected: `one UKI + entry per kernel` ok; `./build.sh client reboot-test` boots the newest.
- [ ] **L5 updates:** `./guest-exec.sh client 'systemctl start <dnf-automatic service>; journalctl -u <service> -n 20; /usr/local/sbin/mld-reboot'` Expected: service ran, `mld-reboot` prints a reason or reboots only without a user session.
- [ ] **L6 build 2:** `CLIENT_DE=kde UKI=0 CIFS_HOME=0 PKI_ENROLL=dcom` → `client iso … verify` Expected: no `FAIL`.
- [ ] **L7 build 3:** build 1 settings with `UKI_TRUST=db` → no `mok-enroll`; `verify` Expected: no `FAIL`.
- [ ] **L8 Ubuntu regression:** separate work tree with the current Ubuntu `lab.env`: `client resume && client wait && client verify` on the existing Ubuntu client. Expected: same result as before the branch.
- [ ] **Step 9:** Update `CLAUDE.md` Gotchas with each confirmed Fedora fact ("seen 2026-MM-DD"), update memory `fedora-client.md`, commit `git commit -m "fedora: live build fixes and confirmed facts"`.
