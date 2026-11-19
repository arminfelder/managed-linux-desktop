# Managed Linux desktop lab

A reproducible libvirt lab that integrates an Ubuntu 26.04 or Fedora 45 desktop with a central identity server and tests the integration end to end. Two settings in `lab.env` select the lab:

- `IDP` selects the identity server in the `dc` role. `windows` (the default) is Windows Server 2025 with AD DS, DNS, AD CS and the file share `Homes$`. `freeipa` is FreeIPA on Fedora 45 (directory, Kerberos, DNS, CA, NFS homes). It has no Microsoft software and no Microsoft protocols ([docs/freeipa.md](docs/freeipa.md)).
- `CLIENT_DISTRO` selects the client OS: `ubuntu` (the default) or `fedora`.

All four combinations build from the same code. With `IDP=windows`, the same code also makes an install image for real hardware.

Integration points on the client:

| | `IDP=windows` | `IDP=freeipa` |
|---|---|---|
| Join | offline domain join (`djoin.exe` blob, Samba `net offlinejoin`), no join password, Kerberos AES256 only | `ipa-client-install` with a one-time password per host |
| Login | sssd `ad`, only for `LinuxUsers` | sssd `ipa`, only by the HBAC rule `mld-linux-login` |
| Home directory | CIFS `sec=krb5` (pam_mount) | NFSv4 `sec=krb5p` (autofs map from IPA) |
| Certificates | AD CS: autoenrollment (certmonger) and manual enrollment (certsrv, DCOM) | IPA CA: machine and user certificate (certmonger) |
| Browser policy | Group Policy through `samba-gpupdate`, ADMX templates in the central store | policy files pulled from the server (`mld-policy`) |
| Office web apps | Microsoft 365 launchers | none |

Both identity servers give these functions: full disk encryption (LUKS2) unlocked by TPM2 (PCR 7), and a signed UKI per kernel through shim and MOK. Private keys are in TPM tokens. Firefox and Chrome get CA trust and Kerberos policy. The snx-rs VPN uses the machine certificate. Updates are automatic, and SELinux is enforcing on Fedora.

A client rebuild from scratch takes about one hour.

## Quick start

You need a Linux host with libvirt/KVM and the host tools in [Prerequisites](#prerequisites). The host needs about 20 GB of RAM (the two VMs take 14 GB). It needs up to 110 GB of disk space: VM disks of 60 and 40 GB (thin-provisioned), plus 9 GB of ISO files. The first full build takes about 1.5 to 2.5 hours, most of it unattended.

```sh
./build.sh setup
```

`setup` asks for the settings and passwords that `lab.env` does not have, `IDP` and `CLIENT_DISTRO` among them. Enter takes the default or generates a password. Then `setup` does everything else without a stop. It downloads and checks the ISO files, makes the libvirt network and pool, and checks the host. It builds and tests the identity server (the `dc` role) and the client, and takes a snapshot of each VM. If it stops, for example after a network problem, run it again: it continues where it stopped.

Then open the client in virt-manager and log in as `alice` with `LAB_USER_PW` from `lab.env`. The step-by-step version with the expected output is [Build the lab](#build-the-lab).

## The lab

| VM | OS | Firmware | Address | Role |
|---|---|---|---|---|
| `mld-dc` (`IDP=windows`) | Windows Server 2025 evaluation | SeaBIOS | 10.110.0.2 | AD DS forest `mld.contoso.com`, DNS, NTP, enterprise CA, share `Homes$` |
| `mld-dc` (`IDP=freeipa`) | Fedora 45, FreeIPA 4.13 | OVMF, Secure Boot | 10.110.0.2 | FreeIPA realm (directory, Kerberos, DNS, CA), NFSv4 homes `sec=krb5p`, policy endpoint `/mld-policy` |
| `mld-client` | Ubuntu 26.04 LTS or Fedora 45 desktop (GNOME or KDE Plasma), selected by `CLIENT_DISTRO` | OVMF, Secure Boot with Microsoft keys, swtpm TPM 2.0 | 10.110.0.20 (DHCP by MAC) | Device under test |

The names and addresses come from `lab.env` (`DC_VM`, `DC_IP`, `CLIENT_VM`, `CLIENT_IP`).

```mermaid
flowchart LR
    subgraph host["Host"]
        build["build.sh<br/>guest-exec.sh"]
        console["lib/console.py<br/>(serial console)"]
    end
    subgraph net["libvirt network mld-lab, 10.110.0.0/24, NAT via 10.110.0.1"]
        dc["mld-dc 10.110.0.2<br/>AD DS or FreeIPA"]
        client["mld-client 10.110.0.20<br/>Ubuntu 26.04 or Fedora 45"]
    end
    build -- "QEMU guest agent" --> dc
    build -- "QEMU guest agent" --> client
    console -- "passphrase, MokManager" --> client
    client -- "Kerberos, LDAP, DNS<br/>windows: SMB 3.1.1, certsrv<br/>freeipa: NFSv4 krb5p, HTTPS /mld-policy, IPA CA" --> dc
```

With `IDP=windows`, the DC uses BIOS on purpose. It is not under test, and Windows Setup from a UEFI CD stops at "Press any key to boot from CD".

## What the client has

| Area | Features | Procedures |
|---|---|---|
| Boot and disk | Secure Boot (shim → grub → kernel, or a signed UKI per kernel). Full disk encryption: ESP and `/boot` plain, the rest LUKS2 → LVM → root. Keyslots: passphrase, recovery key, optional TPM2 (PCR 7) and FIDO2. | [boot-and-disk.md](docs/boot-and-disk.md) |
| Identity and files | AD: join without a join password (offline domain join with a `djoin.exe` blob, as for Windows clients), login through sssd, home directory `\\dc1\Homes$\<user>` over CIFS with `sec=krb5` (`CIFS_HOME=1`), or local. FreeIPA: join with a one-time password, login through sssd and HBAC, home directory `/home/mld/<user>` over NFSv4 with `sec=krb5p` (`NFS_HOME=1`). | [identity-and-pki.md](docs/identity-and-pki.md), [freeipa.md](docs/freeipa.md) |
| Certificates | Machine and user certificates with TPM keys: from AD CS (autoenrollment like Windows, or manual through certsrv and DCOM) or from the IPA CA (certmonger). After a renewal, each TPM token keeps one certificate. The CA certificates are trusted by the system, Chrome and Firefox. | [identity-and-pki.md](docs/identity-and-pki.md), [freeipa.md](docs/freeipa.md) |
| Desktop and apps | GNOME or KDE Plasma (`CLIENT_DE`). Firefox (Mozilla deb on Ubuntu, Fedora package on Fedora) and Chrome without the default-browser prompt and telemetry. With `IDP=windows`, Microsoft 365 apps as Chrome app windows: menu entries, pins and desktop icons from the first login (`O365_APPS`). | [desktop-and-apps.md](docs/desktop-and-apps.md) |
| Management | Browser policy: GPO `MLD Linux Clients` through `samba-gpupdate`, ADMX in the central store (`IDP=windows`), or policy files pulled from the FreeIPA server every 90 min (`mld-policy`, `IDP=freeipa`). Daily automatic updates, reboot at night when nobody is logged in. Boot and login screen with a logo. snx-rs Check Point VPN client, with the machine certificate as second factor. | [management.md](docs/management.md), [freeipa.md](docs/freeipa.md) |
| Real hardware | `IDP=windows`: `./build.sh client hw-iso` makes one install image for a USB stick. No passwords on the stick; the installer asks for them. Offline join blobs per device, signing key made on the device, `mld-firstboot secure` for the recovery key, MOK and TPM2. | [real-hardware.md](docs/real-hardware.md) |

Design decisions, the current status, open items and a comparison with the Red Hat and Canonical AD documentation are in [docs/overview.md](docs/overview.md). The limits that are known today are in [Known limits](#known-limits).

## How the build works

```mermaid
flowchart TD
    cfg["build.sh config<br/>lab.env"] --> fetch["fetch, pin, net, check"]
    fetch --> dciso["dc iso<br/>PROVISION or IPAPROV CD"] --> dcvm["dc vm, dc wait<br/>phases on the identity server<br/>(Windows 1-9, FreeIPA 1-5)"] --> dcv["dc verify, dc snapshot"]
    dcv --> ciso["client iso<br/>remastered ISO + CIDATA"] --> cvm["client vm<br/>autoinstall or kickstart, passphrase"] --> cwait["client wait<br/>mld-firstboot phases"] --> cv["client verify, client snapshot"]
    cv -. "change in lab.env or client/mld" .-> resume["client resume"] --> cwait
```

`build.sh` drives everything. The guests provision themselves. The host talks to them only through the QEMU guest agent (`guest-exec.sh dc|client`).

- **Identity server, `IDP=windows`.** `dc iso` renders `dc/autounattend.xml.tmpl` and `config.ps1` from `lab.env` into the `PROVISION` CD. `dc/provision/run.ps1` then runs the phases below across reboots. The state is in `C:\build\phase`. The result is `C:\build\DONE` or `C:\build\FAILED`. `dc resume` runs the phases again after a change.

  | Phase | Task |
  |---|---|
  | 1 | AD DS |
  | 2 | DNS, time, OUs, users, join account |
  | 3 | share `Homes$` |
  | 4 | WinRM, RDP |
  | 5 | domain facts for the host |
  | 6 | AD CS |
  | 7 | certificate templates |
  | 8 | Linux GPO |
  | 9 | ADMX central store |

- **Identity server, `IDP=freeipa`.** `dc vm` installs Fedora 45 from a kickstart (`ipa/ks.cfg.tmpl`). Then `ipa/provision/run.sh` runs the phases below. The state is in `/var/lib/mld-ipa`. `dc resume` and `dc policy` run phases again.

  | Phase | Task |
  |---|---|
  | 1 | `ipa-server-install` |
  | 2 | users, group, HBAC |
  | 3 | NFS homes, automount |
  | 4 | user certificate profile |
  | 5 | policy endpoint |

- **Client.** `client iso` remasters the ISO of the selected distro and renders the `CIDATA` seed CD. Ubuntu: the live-server ISO boots with `autoinstall ds=nocloud`. Fedora: the Everything netinstall ISO boots with `inst.ks=hd:LABEL=CIDATA:/ks.cfg`, and `client/ks.cfg.tmpl` is the kickstart. The installer sets up LVM on LUKS and the packages, then copies `client/mld/` to `/etc/mld` (list: `client/mld/install.list`). The VM stays off after the install. `client start` boots it with the serial console attached and types the passphrase at the prompt (`lib/console.py`). On first boot, `mld-firstboot.service` runs one phase file per topic in `client/mld/` (`boot ad ipa cert home apps desktop gpo policy vpn update brand selinux`). The topics `ad` and `gpo` run only with `IDP=windows`. The topics `ipa` and `policy` run only with `IDP=freeipa`, and `selinux` runs only on Fedora. The result is `/var/lib/mld/DONE` or `/var/lib/mld/FAILED`. `client resume` copies the changed files and settings to the client and runs the first boot again.
- **Media.** The ISO files are in `data/media`, the VM disks in `data/pool`. `checksums.sha256` pins the Ubuntu ISO, using Canonical's published `SHA256SUMS`. For Fedora, `fetch` downloads the signed `CHECKSUM` file. It checks the signature when `fedora.gpg` (a binary keyring for `gpgv`) is in `data/media`. Without the keyring, `./build.sh pin` records the sum at first download (trust on first use). With `IDP=windows`, Microsoft and virtio-win publish no ISO checksum, so `./build.sh pin` records their sums at first download (trust on first use).

## Repository layout

| Path | Content |
|---|---|
| `build.sh`, `lib/` | The build script and its parts: settings, host checks, identity server (`dc.sh` Windows, `ipa.sh` FreeIPA), client, tests |
| `env.example` | All settings with defaults and help. `build.sh config` writes `lab.env` from it |
| `dc/` | Windows DC (`IDP=windows`): unattended setup and the phases (`dc/provision/0N-*.ps1`) |
| `ipa/` | FreeIPA server (`IDP=freeipa`): kickstart, phases (`ipa/provision/0N-*.sh`), browser policy files (`ipa/policy/`) |
| `client/user-data.tmpl`, `client/ks.cfg.tmpl` | Ubuntu autoinstall, Fedora kickstart |
| `client/mld/<topic>/` | Everything that goes to `/etc/mld` on the client, one folder per topic with its `phase.sh` |
| `tests/` | Host render tests: `tests/render-test.sh all` (see [tests/README.md](tests/README.md)) |
| `docs/` | Topic procedures and [overview.md](docs/overview.md): design, status, open items |

## Procedures

These procedures use ASD-STE100 Simplified Technical English. The topic procedures are in `docs/` (see [What the client has](#what-the-client-has)).

### Prerequisites

- Host tools:
  - libvirt: `virsh`, `virt-install`, `virt-xml`.
  - ISO build: `genisoimage`, `xorriso`.
  - Other: `openssl`, `python3`, `curl`, `swtpm`.
- ImageMagick (`magick`).
- OVMF firmware: `/usr/share/OVMF/OVMF_CODE_4M.secboot.fd`.
- Optional host tool: `sshpass` for the login test.
- Host tools for `CLIENT_DISTRO=fedora`: `mtools` (`mcopy`, `mtype`) to patch the boot menu in the EFI image of the ISO. Optional: `pykickstart` (`ksvalidator`) to check the kickstart syntax in the render test.
- Your user account is a member of the `libvirt` group.
- The VM disks and ISO files are in `data/` in the repo (`DATA_DIR` in `lab.env`). `.gitignore` excludes `data/`.
- The `libvirt-qemu` user must be able to enter each parent directory of `data/` and `.stage/`.
  If `./build.sh check` shows `BAD libvirt-qemu cannot enter`, run the `setfacl` command that the check shows.

NOTE: `/run/media/$USER` is on tmpfs. The ACL on this directory is lost when the host reboots. Then run the `setfacl` command again.

### Select the identity server

1. In `lab.env`, set `IDP=windows` or `IDP=freeipa`.
2. If you use FreeIPA, make sure that `FEDORA_ISO` and `FEDORA_URL` in `lab.env` name the Fedora 45 Everything netinstall ISO. The FreeIPA server and the Fedora client use the same ISO.
3. Do the procedure [Build the lab](#build-the-lab).

NOTE: One identity server has one `IDP`. To change it, remove the server and the client, and build both again. For a lab with both identity servers, use a second work tree with its own `lab.env` (see [docs/freeipa.md](docs/freeipa.md#build-the-lab-with-freeipa)).

### Select the client OS

1. In `lab.env`, set `CLIENT_DISTRO=ubuntu` or `CLIENT_DISTRO=fedora`.
2. If you use Fedora, make sure that `FEDORA_ISO` and `FEDORA_URL` in `lab.env` name the Fedora 45 Everything netinstall ISO.
3. Do the procedure [Build the lab](#build-the-lab).

NOTE: One client VM has one distro. To change the distro of a built client, remove the VM and build it again. If the distro in `lab.env` is not the distro of the client, `client resume` stops with "build the client again".

NOTE: For a second client of the other distro, use a second work tree with its own `lab.env`.

NOTE: Fedora 45 gets no major upgrade from this lab. Only the patch updates inside the release are automatic. Fedora 45 reaches end of life about one month after Fedora 47 is released. To use a newer release, change the ISO settings and build the client again.

### Build the lab

1. In a terminal, run `./build.sh config`.
   The script asks for each setting that `lab.env` does not have. It shows the default in brackets.
2. For each password, type a lab password two times, or push Enter to generate one.
   With `IDP=windows`, Windows password complexity applies to `ADMIN_PW`, `DSRM_PW`, `LAB_USER_PW` and `JOIN_PW`.
   With `IDP=freeipa`, each password must have 8 characters or more.
   The script writes the answers to `lab.env` (mode 600) and shows the values that it took.
3. Run `./build.sh fetch`.
4. If the script shows `NO-SUM` for an ISO (with `IDP=windows`: the Windows and the virtio-win ISO), run `./build.sh pin`.
5. Commit `checksums.sha256`.
6. Run `./build.sh net`.
7. Run `./build.sh check`.
8. If the check shows `MISSING`, `BAD-SUM` or `BAD`, correct the problem before you continue.
9. Run `./build.sh dc iso`.
10. Run `./build.sh dc vm`.
11. Run `./build.sh dc wait`.
    With `IDP=windows`, the DC build takes approximately 30 to 60 minutes.
    With `IDP=freeipa`, the install takes approximately 10 to 30 minutes and the phases approximately 5 minutes.
12. Run `./build.sh dc verify`.
13. Make sure that all lines show `ok`.
14. Run `./build.sh dc snapshot`.
15. Run `./build.sh client iso`.
16. Run `./build.sh client vm`.
    The install takes approximately 15 to 40 minutes.
    Then the script starts the VM and types the passphrase.
17. Run `./build.sh client wait`.
18. Run `./build.sh client verify`.
19. Make sure that all lines show `ok`.
    The script moves the recovery key to `.stage/recovery-key`.
20. Keep `.stage/recovery-key` in a safe location.
21. Run `./build.sh client snapshot`.

`./build.sh setup` does steps 1 to 21 in one run, and `./build.sh all` does steps 7 to 21. Both continue after an interruption: a VM that has the snapshot `post-build` is not built again.

NOTE: Each command asks for missing settings first, for example after an update adds a setting to `env.example`. Without a terminal, the script takes the defaults, generates the passwords, and shows the values that it took. To see all settings, run `./build.sh config`.

### Remove a VM

**CAUTION:** THIS PROCEDURE DELETES THE VM DISK, NVRAM, TPM STATE AND ALL SNAPSHOTS. YOU CANNOT UNDO IT.

1. To remove the client, run `./build.sh client destroy`.
2. To remove the identity server (Windows DC or FreeIPA server), run `./build.sh dc destroy`.
3. Type the VM name when the script asks for it.

NOTE: Do not use `virsh undefine --remove-all-storage`. It also deletes the attached ISO files.

### Log in as a directory user

1. Open the client console in virt-manager.
2. On the GDM login screen (GNOME), click "Not listed?". The SDDM login screen (Ubuntu KDE) asks for the user name immediately. On Fedora KDE, the login screen is Plasma Login Manager: see [desktop-and-apps.md](docs/desktop-and-apps.md#use-kde-plasma-instead-of-gnome).
3. Type the user name, for example `alice`, and the `LAB_USER_PW` password.
4. Open a terminal and run `findmnt -T ~`.
5. With `IDP=windows` and `CIFS_HOME=1`, make sure that the file system type is `cifs` (`/home/alice`).
6. With `IDP=freeipa` and `NFS_HOME=1`, make sure that the file system type is `nfs4` with `sec=krb5p` (`/home/mld/alice`).
7. Log out.
8. With `IDP=windows` and `CIFS_HOME=1`, make sure that the CIFS mount is not there any more.

NOTE: With `IDP=freeipa`, autofs unmounts the NFS home directory some time after the last use, not at logout.

### Apply changed settings to a built client

1. Change the setting in `lab.env`, or change the files in `client/mld/`.
2. Run `./build.sh client resume`.
3. Run `./build.sh client wait`.
   Do not restart the client before the script shows `DONE`.
4. Run `./build.sh client verify`.
5. Make sure that all lines show `ok`. A Chrome Kerberos line shows `open` (see [Known limits](#known-limits)).

NOTE: `client resume` does not change the desktop (`CLIENT_DE`) or the disk layout. For these settings, build the client again.

### Update a built client after a repository update

1. Update the repository, for example with `git pull`.
2. Run `./build.sh client resume`.
3. Run `./build.sh client wait`.
4. Run `./build.sh client verify`.
5. Make sure that all lines show `ok`.

NOTE: The client scripts of this version read `/etc/mld/distro.sh`. A client from an earlier version gets this file only from `client resume`.

NOTE: Each `build.sh` copy reads the `lab.env` file in its own directory. For a second client VM, use a second work tree with its own `lab.env` (other `CLIENT_VM`, `CLIENT_HOSTNAME`, `CLIENT_MAC`, `CLIENT_IP`).

### Set the local admin password again

1. Run `./build.sh client set-admin-password`.
2. Make sure that the script shows `labadmin P` (password set).

NOTE: This procedure applies to Ubuntu. On Ubuntu, cloud-init deletes the password of the installer user at the first boot. `mld-firstboot` sets it again from `CLIENT_ADMIN_PW`, and `client verify` shows `ok local admin has a password`.

NOTE: Fedora has no cloud-init. On Fedora, `client verify` only checks the password.

### Start the client after a shutdown

1. Run `./build.sh client start`.
   The script starts the VM and types the passphrase on the serial console.

### Go back to the snapshot

1. Run `./build.sh dc revert`.
   The script sets the clock of the identity server to the host UTC time. Kerberos rejects a clock skew of more than 5 minutes.
2. Run `./build.sh client revert`.

### Monitor a build

- Identity server phase: `./build.sh dc phase`
- Identity server log: `./build.sh dc log 100`
- Client first-boot log: `./build.sh client log 100`
- Client serial console during boot: `.stage/client-console.log`
- Screen: `./build.sh dc screenshot`, `./build.sh client screenshot`

## Known limits

- With `UKI=0`, `/boot` and the initrd are not signed. PCR 7 does not detect a changed initrd. `UKI=1` closes this gap.
- PCR 7 alone does not protect against a replaced root partition with the same UUID. A TPM2 PIN or a signed PCR 11 policy closes this gap. The lab has neither.
- A db or dbx update changes PCR 7. Then the TPM2 unlock fails. To seal again, run `mld-firstboot enroll-tpm2` with `PASSWORD` set, on a UKI boot.
- `lab.env`, `.stage/dc-provision.iso` (Windows), `.stage/ipa-provision.iso` (FreeIPA) and `.stage/cidata.iso` contain the lab passwords. `.gitignore` excludes them. The client deletes its copies after first boot.
- `IDP=windows`, `CIFS_HOME=1`: `$HOME` on CIFS is the most probable source of desktop problems (dconf, gvfs, flatpak). `/etc/profile.d/mld-xdg-cache.sh` moves `XDG_CACHE_HOME` to local disk. Finding the remaining problems is a purpose of the lab.
- If TPM2 and FIDO2 are both enrolled, `/etc/crypttab` has both options. Not tested: systemd-cryptsetup can use only one of them in this case.
- `IDP=windows`: Microsoft can change the build behind the Windows Server download link. Then the pinned checksum does not match, and `fetch` stops.
- `IDP=windows`: Windows Server 2025 DCs send a KPASSWD reply that MIT Kerberos rejects ("Message stream modified", [realmd/adcli#40](https://gitlab.freedesktop.org/realmd/adcli/-/issues/40)). Because of this, the join uses Samba offline domain join (no kpasswd), not adcli. A password change from Linux (`passwd`, kpasswd) and the sssd machine password renewal also fail against this DC.
- Google Chrome 157 and 158 do no Kerberos (Negotiate) login, with both identity servers: Chrome writes "Unable to create AuthHandler. Status: net::ERR_UNSUPPORTED_AUTH_SCHEME Challenge: Negotiate". The result is the same with the policy allowlist (GPO or `mld-policy`) and with the allowlist as a command-line flag. It is also the same with `--no-sandbox`, with `AuthSchemes` set to `negotiate`, and with an explicit `--gssapi-library-name`. The cause is not known. Firefox does Kerberos with the same ticket. `client verify` shows the Chrome result as `open`, not as `FAIL`.
- A shim update that changes the SBAT level changes PCR 7. After the automatic reboot at night, the client then waits for the passphrase.
- Fedora (`CLIENT_DISTRO=fedora`): SELinux stays enforcing. `client verify` fails on an AVC denial that is not on the ignore list (`client/mld/selinux/avc-ignore.list`).
- Fedora KDE: the login screen is Plasma Login Manager (`plasmalogin.service`). Its package has no setting for the user list that corresponds to SDDM `MaximumUid`. A directory user login on this screen is a manual check (`client verify` shows a warning, not `ok`). If the screen cannot take a typed user name, the fallback is SDDM on Fedora KDE.
- Fedora: the kickstart is not checked offline unless `ksvalidator` (package `pykickstart`) is on the host. Without it, the render test shows `skip ks_validate`, and the first VM build is the first syntax check.
- Fedora: live builds of the Fedora client pass `client verify` with both identity servers (2026-11-18). The done criteria in [docs/superpowers/specs/2026-11-12-fedora-client-design.md](docs/superpowers/specs/2026-11-12-fedora-client-design.md) are not checked one by one.
- Fedora 45 has no major-version upgrade in this lab. It reaches end of life about one month after Fedora 47 is released.
- `IDP=freeipa`: the limits are in [docs/freeipa.md](docs/freeipa.md#known-limits).
- `IDP=windows`, Fedora: the GPO `MLD Linux Clients` adds the Firefox security device `/usr/lib/x86_64-linux-gnu/pkcs11/p11-kit-trust.so`. This path is the Ubuntu path. Fedora has the module in `/usr/lib64/pkcs11/`. The Fedora Firefox package uses the system certificate store. Thus it trusts the AD CA from `update-ca-trust` (live check 2026-11-18: TLS and Kerberos to the DC work).

## License

Apache License 2.0, see [LICENSE](LICENSE). Copyright 2026 Armin Felder. [NOTICE](NOTICE) lists the third-party files in this repository (APT signing keys of Mozilla, Google and snx-rs) and the software that the build downloads.
