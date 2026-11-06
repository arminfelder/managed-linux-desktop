# Managed Linux desktop lab: design, status, comparison

State: 2026-11-05. The procedures are in [README.md](../README.md) (build, operations) and in the topic files in this directory.
This document explains what the lab builds, why, what is verified, what is open, and how the design
compares to the Red Hat and Canonical documentation for direct AD integration.

## 1. Purpose and topology

The lab is a reproducible environment to develop and test a managed Linux client in a Windows-centric
organisation. Everything is built from `lab.env` by `build.sh`; the host talks to the guests only through
the QEMU guest agent.

| VM | OS | Role |
|---|---|---|
| `mld-dc` (SeaBIOS) | Windows Server 2025 evaluation | AD DS forest `mld.contoso.com`, DNS, file server (`Homes$`), AD CS enterprise CA with web enrollment |
| `mld-client` (OVMF Secure Boot, swtpm) | Ubuntu 26.04 LTS desktop | device under test |

Network `mld-lab`, NAT, `10.110.0.0/24` (DC `.2`, client `.20`).

## 2. What the client does, and how

| Requirement | Implementation | Switch | Main files |
|---|---|---|---|
| Secure Boot | OVMF with Microsoft keys; shim → grub → kernel. Always on. | – | `build.sh` (`client_vm`) |
| Full disk encryption | LUKS2 → LVM → root. ESP and `/boot` plain. Passphrase + recovery key keyslot. | – | `client/user-data.tmpl`, `firstboot.sh` |
| TPM2 unlock | `systemd-cryptenroll --tpm2-pcrs=7`, `tpm2-device=auto` in crypttab, dracut | `ENROLL_TPM2` | `firstboot.sh` |
| Signed UKI | dracut `--uefi` + `sbsign` with a lab key. Trust `db`: lab cert added to the NVRAM db (`virt-fw-vars`), firmware entry `MLD UKI`. Trust `mok`: firmware keys unchanged, `mokutil --import` + MokManager confirmation on the serial console, entry `MLD UKI (shim)` = shim with the UKI as second stage. TPM2 is sealed only on a UKI boot. shim + grub stay as fallback; `fallback-test` checks that TPM2 refuses there | `UKI`, `UKI_TRUST` | `client/mld/boot/uki.sh`, `lib/console.py`, `build.sh` (`client_mok_enroll`) |
| FIDO2 unlock | USB pass-through, `systemd-cryptenroll --fido2-device` | `FIDO2_HOSTDEV` | `firstboot.sh` (`enroll-fido2`) |
| AD join | realmd + SSSD, Samba membership (`net ads join`), delegated join account `svc-join` (rights only on `OU=Computers,OU=Linux`) | – | `firstboot.sh`, `dc/provision/02-directory.ps1` |
| AD login | SSSD, `ad_access_filter` on `LinuxUsers`, `ad_gpo_access_control = enforcing`, short names | – | `client/mld/ad/sssd.conf.tmpl` |
| Home directory | `\\dc1\Homes$\<user>` via pam_mount, CIFS `sec=krb5`, SMB 3.1.1, encrypted; or local home (`pam_mkhomedir`) | `CIFS_HOME` | `pam_mount.conf.xml.tmpl`, `firstboot.sh` |
| DNS | systemd-resolved global DNS = DC (`Domains=<domain> ~.`). The dracut `systemd-networkd` module leaves `/run/systemd/network/zzzz-dracut-default.network` (DHCP, libvirt DNS) after switch-root; `firstboot` masks it in `/etc` and omits the network modules from the initrd. NetworkManager (`netplan-lan`) also pushes the DHCP DNS despite `use-dns: false`: `dns=none` + `systemd-resolved=false`. `client verify` checks that no link has a DNS server other than the DC | – | `firstboot.sh` (`dns`, `write_dracut_conf`) |
| PKI | AD CS enterprise root CA, certsrv over HTTPS, DCOM | `PKI_ENROLL` | `dc/provision/06-adcs.ps1` |
| Certificate autoenrollment | Windows-like: published templates, v2, autoenroll flag, Enroll + Autoenroll in the template ACL (account + `tokenGroups`). certmonger tracks and renews; keys in `tpm2-pkcs11` tokens (machine: `/etc/tpm2_pkcs11`, user: `~/.tpm2_pkcs11`). Submission through certsrv or DCOM (`ICertRequestD`, impacket). | `PKI_ENROLL` (`web`/`dcom`/`none`) | `dc/provision/07-templates.ps1`, `client/mld/cert/autoenroll.py`, `cm-submit.sh`, `cert.sh`, `cert-dcom.py` |

### Server 2025 specifics the design had to absorb

| Finding | Effect | Response |
|---|---|---|
| KPASSWD reply with error code 0 ("Message stream modified", [realmd/adcli#40](https://gitlab.freedesktop.org/realmd/adcli/-/issues/40)) | `adcli join` and every Kerberos password change from Linux fail | join with `--membership-software=samba`; password change from Linux and SSSD machine-password renewal still fail (open, §5) |
| `/certsrv` requires SSL after `Install-AdcsWebEnrollment` (403.4) | HTTP enrollment fails | HTTPS binding with the DC's autoenrolled certificate; client gets the CA certificate over LDAP (GSSAPI) first |
| LDAP signing required | plain binds fail | all LDAP access is SASL GSSAPI (signed) |
| A request into `LocalMachine\My` runs as `DC1$` | `WebServer` request denied | use the DC's own autoenrolled certificate (`certutil -pulse`) |
| NIC stays in the `Public` network profile | Domain-only firewall rules do not apply | certsrv and DCOM work anyway (rules with profile `Any`); `dc verify` warns |

## 3. Verification

| Command | What it proves |
|---|---|
| `./build.sh dc verify` | domain, SRV record, `dcdiag`, share + encryption, user folders + ACL, CA service, templates, HTTPS certsrv, clock skew |
| `./build.sh client verify` | Secure Boot, LUKS2, keyslots/tokens, root on dm-crypt, plaintext partitions, crypttab, UKI boot, realm, AD user, recovery key, ssh login with Kerberos ticket, home (CIFS write + DC read-back, or local), autoenrolled machine certificate in the TPM token |
| `./build.sh client reboot-test` | TPM2 (or FIDO2) unlocks without passphrase |
| `./build.sh client mok-enroll` | `UKI_TRUST=mok`: MOK request, MokManager confirmation, boot shim → UKI, TPM2 seal on that path |
| `./build.sh client fallback-test` | TPM2 refuses on the shim + grub path; the passphrase unlocks |
| `./build.sh client pki-test` | manual enrollment, machine + user, certsrv + DCOM, TPM key, signature, chain |
| `./build.sh client autoenroll-test [web\|dcom]` | autoenrollment and renewal for machine + user through either path |

Verified on the running lab (2026-11-05): all of the above, including renewal (new serial) and user
renewal via DCOM. Every client fix was also applied through `client resume`; a fully fresh build of
both VMs is in progress (§5).

## 4. Comparison with the vendor documentation

Sources: Red Hat *Integrating RHEL systems directly with Windows Active Directory* (RHEL 8; the HTML and
PDF block automated download, so this comparison uses the official chapter excerpts found by search:
[guide](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/8/html-single/integrating_rhel_systems_directly_with_windows_active_directory/index),
[chapter 1](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/8/html/integrating_rhel_systems_directly_with_windows_active_directory/connecting-rhel-systems-directly-to-ad-using-sssd_integrating-rhel-systems-directly-with-active-directory),
[chapter 4](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/8/html/integrating_rhel_systems_directly_with_windows_active_directory/managing-direct-connections-to-ad_integrating-rhel-systems-directly-with-active-directory),
[KCS 1350723](https://access.redhat.com/solutions/1350723));
Ubuntu Server docs ([AD integration intro](https://ubuntu.com/server/docs/explanation/intro-to/AD-integration/),
[SSSD with AD](https://canonical-ubuntu-server-documentation.readthedocs-hosted.com/how-to/sssd/with-active-directory/));
ADSys ([certificates](https://documentation.ubuntu.com/adsys/stable/explanation/certificates/)).

| Topic | Vendor guidance | Lab | Assessment |
|---|---|---|---|
| Join tool | realmd + SSSD is "the most convenient way"; `realm join` uses adcli by default; Winbind via `--membership-software=samba --client-software=winbind` | realmd + SSSD, `--membership-software=samba --client-software=sssd` | same stack; Samba membership forced by the Server 2025 KPASSWD bug. Side effect (third-party note): Samba membership does not support `--use-ldaps` |
| Packages | RHEL: `samba-common-tools realmd oddjob oddjob-mkhomedir sssd adcli krb5-workstation` | Ubuntu equivalents + `samba-common-bin` | equivalent |
| Crypto policy | RHEL 8 needs `DEFAULT:AD-SUPPORT` (RC4) to join | Ubuntu default; Server 2025 has RC4 off; join and Kerberos run on AES | not applicable; AES-only is the better target. Not explicitly verified with `klist -e` |
| ID mapping | automatic ID mapping by default; `--automatic-id-mapping=no` for POSIX attributes in AD | automatic ID mapping | same default. Note: UIDs differ from any POSIX attributes a Windows admin may set |
| Machine password renewal | SSSD renews the host keytab automatically when adcli is installed (`ad_maximum_machine_account_password_age`, 0 = off) | default SSSD setting; renewal through adcli fails against Server 2025 (KPASSWD) | **gap**, open (§5) |
| Home directories | `oddjob-mkhomedir` (local home) | pam_mount CIFS with Kerberos, or `pam_mkhomedir` | goes beyond the guide (network home); oddjob vs pam_mkhomedir is a detail |
| GPO access control | `ad_gpo_access_control` default `enforcing`; built-in groups (e.g. `S-1-5-32-544`) not supported in GPO security filters | `enforcing`, but no Linux GPO in the lab | **untested**: needs a GPO with logon rights for the Linux OU (§5) |
| Short names | domain resolution order | `use_fully_qualified_names = False` | adequate for one domain |
| Ports | dedicated chapter (port table) | one NAT network, no client firewall | not exercised; relevant once the client firewall is on |
| Leaving the domain | `realm leave` chapter | VMs are destroyed; the computer object stays in AD | **gap**: rebuild re-uses the `LNX01` object (works, but no clean leave) |
| Certificate autoenrollment | not part of the RHEL 8 direct-integration guide (not found); Canonical: ADSys, Ubuntu Pro only; ADSys "LDAP" method discovers CAs/templates via LDAP, submits via MS-ICPR (DCOM/RPC), renews within 30 days, not tracked by certmonger, no TPM mentioned; legacy method needs CEP/CES + cepces | own AD-driven autoenrollment: same discovery and submission idea as ADSys-LDAP, plus certmonger tracking and TPM-bound keys, no Ubuntu Pro, no CEP/CES | goes beyond both; self-built component, needs maintenance |
| Secure Boot, LUKS, TPM2, UKI, FIDO2 | out of scope of both AD guides | implemented | – |

## 5. Open items

| # | Item | Status / next step |
|---|---|---|
| 1 | Fresh build of both VMs (`./build.sh all`) | in progress; found and fixed two first-run bugs (DC certificate request in machine context, CA restart race) |
| 2 | Machine account password renewal against Server 2025 | SSSD/adcli renewal fails (KPASSWD). Options: `ad_update_samba_machine_account_password`, a timer with `net ads changetrustpw`, or wait for a Microsoft fix. Test needed |
| 3 | Linux GPO for logon rights (`ad_gpo_access_control = enforcing`) | not configured; add a GPO on `OU=Computers,OU=Linux` and test allow/deny |
| 4 | GDM desktop login with CIFS home | not tested; expected trouble with dconf/gvfs on CIFS |
| 5 | CIFS mount after logout | cause found 2026-11-06 (pam_mount debug): at ssh logout `umount` fails with `target is busy`, because the user manager runs 10 s longer (UserStopDelaySec); nothing retried. Fix: `user@.service` drop-in `ExecStopPost=mld-home-umount %i` |
| 6 | FIDO2 unlock | implemented, not tested (needs the physical key) |
| 7 | Token PIN of the machine TPM token appeared in a log once | rotate: rebuild the token (fresh build covers it) |
| 8 | Passwords from Linux (`passwd`, kpasswd) | fail against Server 2025 (KPASSWD); document for users or test a workaround |
| 9 | Clean domain leave on destroy (`realm leave`, delete computer object) | not implemented |
| 10 | `klist -e` check that only AES enctypes are used | not verified |
| 11 | Slow package download during the client install (~0.4 MB/s, host 52 MB/s, DC via the same NAT 37 MB/s) | cause unconfirmed; `unattended-upgrades` in the live installer is now stopped; measure on the next install |
| 12 | One `Permission denied` before a successful ssh password login in `client verify` | seen once, not investigated |
| 13 | `UKI_TRUST=mok` (shim + MOK, firmware keys unchanged) | verified on the VM 2026-11-06 step by step (`mok-enroll`, `reboot-test`, `fallback-test`, `verify` all ok). Not yet verified: one uninterrupted `./build.sh all` with `UKI_TRUST=mok`, and `UKI_TRUST=db` after these changes |
| 14 | Replaced-root attack with PCR 7 only | open; TPM2 PIN or signed PCR 11 policy (ukify) |

## 6. Security notes (lab only)

- `lab.env`, `.stage/` (CIDATA, recovery key, lab Secure Boot key) contain secrets; both are git-ignored.
- With `UKI=1` the client keeps the lab signing key (`/etc/mld/sb`, mode 600) to re-sign UKIs after kernel updates. A production client must not hold the signing key.
- TPM token PINs are random, stored root-only (machine) or user-only (user). The key material never leaves the TPM; the PIN protects use, not extraction.
- `LinuxUsers` members may open `/dev/tpmrm0` (udev rule) to make their own TPM keys.
