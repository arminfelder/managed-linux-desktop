# FreeIPA as Microsoft-free alternative to the Windows DC

Status: approved 2026-11-18. Not built. Spikes S1-S5 not run.

## Context

User wants a lab stack free of Microsoft products and Microsoft protocols. Windows DC stays the default; a lab.env switch selects a FreeIPA server instead. User decisions (2026-11-18):

- Stack **FreeIPA** (no Samba AD: no MS protocols). Windows path **kept**, switch added. O365 launchers only with the Windows DC.
- Base branch **`fedora-client`** (abb03e1); `main` (3458112) has no Fedora code. Branch `freeipa` from `fedora-client`.
- Server OS **Fedora 45**. Home **NFSv4 `sec=krb5p` + autofs**. Policy **pulled from the IPA server** (no GPO).
- Ubuntu client: use `freeipa-client` if Ubuntu 26.04 has a working one; else a **hand-made join** (sssd `id_provider=ipa` + `ipa-getkeytab`, no ipa-client-install).
- NTP on freeipa: **`pool.ntp.org` only** (no `time.windows.com`).

Line refs = `fedora-client` blobs (recon + builder review 2026-11-18). [fact]/[belief] labels are from the review; beliefs are spike items.

## Phase 0: spikes (throwaway, before the plumbing)

Run by hand in VMs (user `!`), results go to CLAUDE.md gotchas + memory:

1. **S1 server**: F45 netinstall VM, `ipa-server-install` with the flags below, `--no-dnssec-validation` against the libvirt forwarder `NET_GW`, firewalld `freeipa-4 dns nfs`, 4 GB RAM / 2 vCPU / 30 GB. Firmware: q35 + OVMF without TPM (F45 BIOS boot not confirmed). Confirms package names (P1 server), RAM (P5).
2. **S2 Fedora client home**: `ipa-client-install --automount-location=default`, ssh + GDM password login, `findmnt` nfs4 `sec=krb5p`; KCM vs FILE ccache (`/etc/krb5.conf.d/0-mld-ccache`), rpc.gssd reads `/tmp/krb5cc_<uid>` under SELinux (note AVCs exactly), `use_nfs_home_dirs`, sssd socket units (ssh/sudo/autofs) not failed, renewal settings.
3. **S3 certmonger**: machine `getcert request -c IPA` into the tpm2-pkcs11 NSS token; session certmonger user CA `ipa-submit -K -T mldUserCert` + CA ACL; renew (resubmit).
4. **S4 policy endpoint**: `/mld-policy/` Location via gssproxy (no `GssapiCredStore`), 401 without ticket, 200 with host ticket.
5. **S5 Ubuntu 26.04**: apt probe `freeipa-client`, `ipa-client-install` + `ipa-client-automount` trial. Outcome picks the Ubuntu join path (ipa-client-install vs hand-made).

## Design

### Switch + settings

- `IDP=windows|freeipa` in `env.example` (before gated settings), `S_CHOICES[IDP]` (`lib/settings.sh:14-17`), default + regex + export in `lib/config.sh` (pattern `CLIENT_DISTRO` `config.sh:29-44`).
- `S_WHEN` (`settings.sh:20-31`): `WINSERVER_* VIRTIO_* WIN_IMAGE_INDEX AD_LEVEL DSRM_PW REGISTERED_OWNER CA_NAME JOIN_* SMB_ENCRYPT CIFS_HOME` → `IDP=windows`; `FEDORA_*` → `CLIENT_DISTRO=fedora || IDP=freeipa`; new `IPA_DM_PW` (secret), `NFS_HOME` (default 1) → `IDP=freeipa`.
- `PKI_ENROLL`: windows `web|dcom|none`, freeipa `ipa|none` (default `ipa`); `firstboot.sh:79` and `build.sh:155` branch on it.
- Derived in `config.sh`: `HOME_MODE` (windows: cifs/local from `CIFS_HOME`; freeipa: nfs/local from `NFS_HOME`), `O365_APPS` (windows 1, freeipa 0, overridable), `IDM_GROUP` (= `LINUX_GROUP` on windows, `${LINUX_GROUP,,}` on freeipa: IPA lower-cases names, sssd ipa is case-sensitive), `IDP_NTP` (freeipa: `pool.ntp.org`), `IDP_HOSTNAME` (freeipa: lower-case `DC_HOSTNAME`).
- Same role `dc`, same `DC_VM`/`DC_HOSTNAME`/`DC_IP` (.2): `phase_dns` (`ad/phase.sh:12-85`) unchanged.
- config.env (`lib/client.sh:66,187,535`): `IDP HOME_MODE O365_APPS` written **only when `IDP=freeipa`** (missing = windows defaults) → Ubuntu baseline byte-identical. freeipa omits `LINUX_OU DOMAIN_DN JOIN_USER CA_NAME`.

### Host / build side

- `build.sh:71-82`: source `lib/dc.sh` (windows) or `lib/ipa.sh` (freeipa). `lib/ipa.sh` has its own `cmd_dc`, `dc_phase_name`, `dc_skew` and API: `dc_iso dc_vm dc_start dc_status dc_wait dc_ready dc_phase dc_log dc_resume dc_verify dc_revert dc_set_passwords dc_read_home_file` + subcommand `dc policy`. `dc_certsrv_diag` windows only.
- Media: `media_files` (`common.sh:10`), `cmd_fetch` (`host.sh:100-106`), `cmd_setup` (`build.sh:169-170`): Windows + virtio only for windows; `FEDORA_ISO` once if client or server needs it.
- `iso_inputs` (`common.sh:13-28`): dc role on freeipa hashes `ipa/`, `lib/ipa.sh`, `lib/fedora.sh`, `FEDORA_ISO` stat; client vars add `IDP`, client files add `lib/fedora.sh`.
- `guest-exec.sh:34-50`: pass `IDP`; dc + freeipa → bash via `/usr/libexec/mld/qemu-ga-run`. `guest_run` (`common.sh:254-263`): `%q` prefix for `dc:freeipa`. Admin snippets get `ADMIN_PW` as variable and `kinit admin` into a MEMORY ccache.
- `lib/fedora.sh`: `fedora_grub_patch`/`fedora_grub_sed`/remaster from `lib/client.sh:226-254`, parameterised by output name (`fedora-ipa-ks.iso`, label `IPAPROV`); the `rm -f "$STAGE"/fedora-grub-*` scoped per output.
- `lib/tests.sh:187` (`Get-Content C:\Homes\…`) → `dc_read_home_file USER FILE` (windows: today's PowerShell; freeipa: `cat /export/home/USER/FILE`).

### IPA server VM (`ipa/`, `lib/ipa.sh`)

- `ipa/ks.cfg.tmpl`: static `DC_IP`, hostname `IDP_HOSTNAME.DOMAIN` (lower case), `selinux --enforcing`, `rootpw --lock`, `%packages` `freeipa-server freeipa-server-dns nfs-utils qemu-guest-agent`, `%post`: qemu-ga-run + boolean `virt_qemu_ga_run_unconfined` + fcontexts (`semanage -N`), enable `mld-ipa-provision.service`, default `multi-user.target`. VM: q35 + OVMF (no TPM), `--serial pty`, `--noreboot` then start (pattern `client_vm` `lib/client.sh:339-362`).
- Runner `ipa/provision/run.sh`: bash port of the run.ps1 contract: `/var/lib/mld-ipa/{phase,DONE,FAILED}`, `provision.log`, systemd oneshot, `set -E` + ERR trap. `ipa/guest/status.sh` → `{phase,done,failed,utc}` (`dc.sh:105-107` contract).
- Phases:
  1. `01-install.sh`: `ipa-server-install -U --realm REALM --domain DOMAIN --hostname FQDN --ip-address DC_IP --ds-password IPA_DM_PW --admin-password ADMIN_PW --setup-dns --forwarder NET_GW --forward-policy=only --no-dnssec-validation --reverse-zone REVERSE_ZONE --idstart 200000 --idmax 299999 --ntp-pool pool.ntp.org`. firewalld `freeipa-4 dns nfs`.
  2. `02-directory.sh`: `ipa config-mod --homedirectory=/home/mld`; group `IDM_GROUP`; users `LAB_USERS` with `LAB_USER_PW`, `--homedir /home/mld/<user>`, expiry cleared (`ipa user-mod --password-expiration=` [belief]; fallback ldapmodify `krbPasswordExpiration` as Directory Manager), also for `admin`; hostgroup `linux-clients` + automember rule; HBAC `mld-linux-login` (IDM_GROUP → linux-clients, all services), `allow_all` disabled.
  3. `03-nfs.sh`: `/export/home/<user>` (owner, 0700), `/etc/exports` `sec=krb5p,rw,root_squash`, `ipa service-add nfs/FQDN` + `ipa-getkeytab -p nfs/FQDN -k /etc/krb5.keytab`, `nfs-server` enabled; automount location `default`: `auto.master` key `/home/mld` → map `auto.home`, key `*` = `-fstype=nfs4,sec=krb5p,rw FQDN:/export/home/&`.
  4. `04-pki.sh`: profile `mldUserCert` (from `caIPAserviceCert`, subject CN = uid, EKU clientAuth), CA ACL `mld-users` (IDM_GROUP → mldUserCert). Machine certs use the stock `hosts_services_caIPAserviceCert` ACL.
  5. `05-policy.sh`: `/etc/httpd/conf.d/mld-policy.conf`: `Alias /mld-policy /var/lib/mld-ipa/policy`, `AuthType GSSAPI`, `GssapiAllowedMech krb5`, `Require valid-user`, no `GssapiCredStore` (gssproxy); fcontext `/var/lib/mld-ipa/policy(/.*)?` = `httpd_sys_content_t` + restorecon.
- `dc_verify` (JSON + Python, pattern `dc.sh:209-252`): `ipactl status` RUNNING, SRV `_kerberos._udp`/`_ldap._tcp`, users + group, HBAC enabled + `allow_all` disabled, admin expiry cleared, NFS export + automount key, profile + ACL, policy URL 401 without ticket, skew.
- `dc_resume` (pattern `dc.sh:189-207`): push `ipa/provision/*` + config, clear DONE, restart unit.

### Policy pull (replaces GPO on freeipa)

- Repo `ipa/policy/`: `mld-policy-kerberos.json.tmpl` (Chrome `AuthServerAllowlist=*.DOMAIN`), `firefox-policies.json.tmpl` with placeholder `@P11KIT_TRUST@` (Firefox `Authentication.SPNEGO`, `SecurityDevices` p11-kit-trust), `manifest` (name, target class, sha256). `build.sh dc policy` renders + pushes + restorecon (also phase 5 / `dc resume`).
- Client topic `policy/` (replaces `gpo` on freeipa): `mld-policy` + `mld-policy.{service,timer}` (90 min). Steps: `kinit -k host/FQDN` (private ccache) → `curl --negotiate --cacert /etc/ipa/ca.crt https://DC_FQDN/mld-policy/manifest` → fetch, check sha256 → substitute `@P11KIT_TRUST@` with the distro path (`PKCS11_DIR` in `distro.sh`) → atomic install to `/etc/opt/chrome/policies/managed/mld-policy-*.json` and `/etc/firefox/policies/policies.json` (Fedora symlink `apps/phase.sh:33-36` stays). Cleanup only `mld-policy-*` (keeps `mld-ca.json`). Fetch failure keeps last good files. Then `mld-cert ca`.
- CA: `mld-ipa-certupdate.timer` daily runs `ipa-certupdate`; `mld-cert ca` on freeipa syncs `/etc/ipa/ca.crt` into the `mld-*` anchor + Chrome `mld-ca.json` (generic code `cert.sh:168-184`).
- Trust: TLS (IPA CA) + Kerberos host auth, no extra signature (builder call: same trust level as GPO over SMB/LDAP).

### Client side

- **install.list col 4** tags: `all|ubuntu|fedora|windows|freeipa|<distro>+<idp>`; `install_list`/`install_list_file` (`lib/client.sh:6-15`) match both. `CLIENT_TEMPLATES` (`:43`) per IDP. Firstboot topic loop (`firstboot.sh:44`) skips absent topic files (guard like selinux).
- **Packages** (`user-data.tmpl:42-52,63-66`, `ks.cfg.tmpl:27-36,48-51`): `@@IDP_PACKAGES@@`. windows = today. freeipa: Fedora `freeipa-client nfs-utils autofs`; Ubuntu per S5 (`freeipa-client` or `sssd-ipa krb5-user` for hand-made) + `nfs-common autofs`. `certmonger` stays in both; impacket/ldap-utils/sasl-gssapi windows only; `autoenroll.py` impacket import made lazy.
- **Kickstart/user-data `%post`**: `chmod 600 odj.txt` (`ks.cfg.tmpl:75`) only when present / per IDP (`ipa-otp.txt`); `phase_cleanup` (`firstboot.sh:57`) shreds `ipa-otp.txt` too.
- **Join** topic `ipa/phase.sh`:
  - Host `join_provision` (replaces call site `client.sh:192`): windows = `odj_provision`; freeipa = `guest_run dc ipa/guest/host-add.sh Machine=<lower fqdn> Ip=CLIENT_IP Otp=<host-generated> Replace=1` (`host-del --updatedns` first, `host-add --password=OTP --ip-address`) → `.stage/join/NAME.otp`, CIDATA `ipa-otp.txt`, hashed in `iso_inputs`.
  - `phase_join_freeipa` (ipa-client-install path): `ipa-client-install -U --password "$OTP" --domain DOMAIN --server DC_FQDN --realm REALM --hostname FQDN --ntp-pool pool.ntp.org --automount-location=default` (no `--mkhomedir`), shred, `$STATE/join.done`.
  - Hand-made Ubuntu path (if S5 fails): settle the OTP→keytab step in S5; fallback: host makes the keytab on the server (`ipa-getkeytab` in `host-add.sh`), CIDATA carries the keytab instead of the OTP (secret, shredded like the blob), client writes sssd.conf (`id_provider=ipa`, `ipa_server`, `ipa_domain`, `autofs_provider=ipa`, `ipa_automount_location=default`), krb5.conf, `/etc/ipa/ca.crt` (from CIDATA), nsswitch `automount: sss`. Templates `ipa/sssd.conf.tmpl`, `ipa/krb5.conf.tmpl`.
  - Join guard `firstboot.sh:77` (`realm list`) windows only; `cmd_join` (`:156-162`) takes OTP/keytab on freeipa.
- **sssd/krb5** (`ad/phase.sh:107-127`): on freeipa skip both template installs `:110-111`; disable every socket unit whose responder is in `services` (nss pam pac ssh sudo autofs); `/etc/sssd/conf.d/mld.conf` `krb5_ccname_template = FILE:/tmp/krb5cc_%U`, `krb5_renewable_lifetime`, `krb5_renew_interval`; `/etc/krb5.conf.d/0-mld-ccache` `default_ccache_name = FILE:/tmp/krb5cc_%{uid}` (sorts before `kcm_default_ccache`, no dot in the name). Authselect + getent wait unchanged.
- **Home** (`home/phase.sh:94` 3-way on `HOME_MODE`): `pam_nfs_home`: enable `autofs`, `rpc-gssd`, `nfs-client.target`; no pam_mount; `xdg-cache.sh` installed (caches local); `user-home-umount.conf` + `mld-home-umount` tagged `windows`. Per-device TPM state `/var/lib/mld-users/<uid>` stays (home roams).
- **PKI** (`cert/`): `autoenroll.py --idp freeipa`: machine = `getcert request -c IPA -K host/FQDN -D FQDN -N CN=FQDN -d sql:/etc/mld/pki/nssdb -t mld-machine -P <pin>` (token reuse: `setup()` :278-331, `user_state` :41-73, `store_contents` :264-275); user = session CA `getcert add-ca -s -c mld-ipa-user -e '/usr/libexec/certmonger/ipa-submit -K -T mldUserCert'` with the user's FILE ccache. `cm-submit.sh`, `cert-dcom.py`, `pki_wait_certsrv`, `cert/phase.sh:68` config tagged windows. SELinux fcontext `mld-cm-submit` windows only.
- **Desktop**: `O365_APPS=0` → skip loop, remove `mld-o365-*.desktop` + icons + pins (`desktop/phase.sh:11-31`, `desktop_pins` :129); verify `tests.sh:69-70,75,90` gated.
- **VPN**: unchanged (one cert on `mld-machine`, `tests.sh:140-142`).
- **SELinux** (Fedora): `booleans.list` per IDP (`use_nfs_home_dirs` vs `use_samba_home_dirs`); new `mld.te` rules only from AVCs seen in S2/live.
- **firstboot main** (`firstboot.sh:64-94`): `phase_join_${IDP}`; `phase_gpo` windows; `phase_policy` freeipa; `phase_pki` dispatch on `PKI_ENROLL`.
- `client_check_idp` (like `client_check_distro`): resume on other IDP dies "build the client again". `client hw-iso` dies on freeipa (non-goal).

### Verify (`lib/tests.sh`, `client/guest/verify-facts.sh`)

freeipa branches: keytab `host/FQDN` + `kinit -k` (replaces `:42-45`); sssd domain provider ipa; policy files match manifest + timer (replaces `:63-64`); certmonger machine MONITORING, issuer IPA CA, CA trusted, policy URL TLS 401 (replaces `:135-139`); login `fs=nfs4` + `sec=krb5p` + `dc_read_home_file` probe (`:151-191`); browser probe `https://DC_FQDN/mld-policy/manifest` (`browser-kerberos.sh:7`); `client ipa-cert-test` (issue + renew) instead of `client_pki_test`/`client_autoenroll_test`.

### Non-goals

hw-iso on freeipa; AD trust; Windows clients; IDP migration of an existing client; Samba on IPA; policy authoring UI.

## Implementation order

0. Spikes S1-S5; record facts.
1. Branch `freeipa` from `fedora-client`; commit this design.
2. Switch plumbing (settings, config, config.env rule, install.list tags, iso_inputs). `tests/render-test.sh all` → Ubuntu baseline unchanged.
3. Package probe: extend `tests/fedora-probe.sh` + fixture; Ubuntu apt probe.
4. Host: `lib/fedora.sh`, `lib/ipa.sh`, guest-exec/guest_run, media gating, `ipa/` (ks, provision, guest, policy).
5. Client: `ipa` topic, sssd/krb5 changes, home nfs, cert freeipa, `policy` topic, O365 gate, firstboot dispatch, packages/templates, SELinux lists.
6. Verify + render-test `FREEIPA_TESTS` (ipa ks render, config.env, CIDATA has `ipa-otp.txt` not `odj.txt`, no O365 launchers, tag filter, policy render per distro).
7. Docs: `docs/identity-and-pki.md` FreeIPA section, README, CLAUDE.md gotchas, env.example comments (STE for procedures).

## Verification

- Sandbox: `bash -n` all shell; `python3 -m py_compile lib/console.py client/mld/cert/autoenroll.py`; `tests/render-test.sh all` (Ubuntu baseline unchanged, Fedora set green, FREEIPA set green); `ksvalidator` if installed.
- Live (user `!`, own work tree like `data/kde-client`, `IDP=freeipa`):
  - `./build.sh dc vm && ./build.sh dc wait && ./build.sh dc verify` → all ok.
  - `./build.sh client vm` (Fedora) → DONE; `./build.sh client verify` → all ok, no unmatched AVC.
  - Login → `findmnt /home/mld/<user>` nfs4 `sec=krb5p`; probe file on server.
  - `getcert list` machine + user MONITORING; `pkcs11-tool` one cert on `mld-machine`.
  - Policy change → `./build.sh dc policy` → `systemctl start mld-policy` → file updated.
  - Same with `CLIENT_DISTRO=ubuntu`.
- Regression: windows render = baseline; one live `client verify` on the existing Windows lab after merge.

## Spike results

S1 + S4 (server side), 2026-11-18, VM `mld-ipa-spike` (10.110.0.3, domain `mldipa.test`, files in `data/spike-ipa/`):

- Packages (F45): `freeipa-server`, `freeipa-server-dns`, `freeipa-client` 4.13.4-3.2.fc45; `nfs-utils` 2.9.2-1.rc1.fc45.1; `certmonger` 0.79.21-10.fc45; `autofs` 5.1.9-15.fc45. 4 GB / 2 vCPU: `ipa-server-install` 201 s.
- Design change: phase 1 needs `--allow-zone-overlap`. Without it: `DNSZoneAlreadyExists: DNS zone 0.110.10.in-addr.arpa. already exists in DNS and is handled by server(s): []`.
- Design change: the provision runner must be in `/usr/local/sbin` or `/usr/libexec` (`bin_t`). From `/root` (`admin_home_t`) systemd fails `203/EXEC` (AVC `init_t` execute).
- Confirmed: DNS forward with `--no-dnssec-validation`; `ipa user-mod --password-expiration=` clears the forced change (kinit rc 1 → 0); admin expiry is +90 days by default; `ipa user-add --password` reads two lines from stdin; HBAC + `allow_all` off; hostgroup automember; nfs service + keytab; automount map + keys; profile `mldUserCert` (copy of `caIPAserviceCert`) + CA ACL → user self-request with own ticket (subject `O=REALM, CN=<uid>`, no SAN, EKU serverAuth + clientAuth); policy Location via gssproxy: 401 / 200 (admin) / 200 (host).
- Open: AVC `rpcbind_t` `name_bind` `unreserved_port_t` (udp), effect unknown.
- Not run yet: S2, S3, S5, S4 from a client.

S2 + S3 + S4 (client side), 2026-11-18, VM `lnx-spike` (10.110.0.30, F45 minimal, swtpm), joined to `mld-ipa-spike` by OTP:

- `ipa-client-install -U --password OTP … --automount-location=default`: rc 0. Host ticket etype `aes256-cts-hmac-sha384-192`. Profile `sssd` (with-sudo), sssd `services = nss, pam, ssh, sudo, autofs`. No failed unit and no enabled `sssd-*.socket` after join, after sssd restart and after login (review item M1 does not happen on F45).
- `/etc/krb5.conf.d/0-mld-ccache` + sssd `conf.d/50-mld.conf` (`krb5_ccname_template`, renew 7d/60m) → ssh password login gets `FILE:/tmp/krb5cc_200004`, TGT `renew until` +7 d, and an `nfs/` service ticket.
- Home: `/home/mld/alice` = `ipa1.mldipa.test:/export/home/alice` nfs4 vers=4.2 `sec=krb5p`, mounted by autofs at login; `chmod 755` works (mode 755); symlinks work. UID 200004 (idstart 200000 holds).
- **Zero AVCs** on the client for the whole run (join, ccache, NFS krb5p login, TPM token, certmonger): no `gssd_t` rule needed, `use_nfs_home_dirs on` was set.
- Machine cert: `getcert request -c IPA -K host/FQDN -D FQDN -N CN=FQDN -d sql:/etc/mld/pki/nssdb -n mld-machine -t mld-machine -p token.pin` → MONITORING, issuer IPA CA, key + cert in TPM token `mld-machine` (fcontext `cert_t` for `/etc/tpm2_pkcs11`, `/etc/mld/pki`). certmonger also imports the cert into the NSS soft token.
- **Finding:** `getcert resubmit` reuses the key and leaves **two cert objects with the same CKA_ID** in the TPM token (pkcs11-tool). snx-rs/`client verify` want exactly one cert: the renewal path needs a cleanup of old cert objects (post-save command). Unknown whether the AD path does the same (not checked).
- User cert: session CA `getcert add-ca -s -c mld-ipa-user -e '/usr/libexec/certmonger/ipa-submit -K -T mldUserCert'` + `getcert request -s … -K alice@REALM` with the login ccache → MONITORING, `CN=alice,O=REALM` (review item E8 confirmed). TPM errors in the user session (`/dev/tpmrm0: Permission denied`) are from p11-kit loading tpm2-pkcs11 for a user outside the TPM group: expected in the spike.
- Policy from client: host ticket 200, no ticket 401.
- PTR for the client: `host-add --ip-address` warned `DNS reverse zone 30.0.110.10.in-addr.arpa. … is not managed by this server`, but `dig -x 10.110.0.30` from the client later answers `lnx-spike.mldipa.test.` (cause not checked).
- Not covered: GDM login, ticket expiry with renewal, reboot, S5 Ubuntu.

S5 (Ubuntu 26.04.1 client), 2026-11-18, VM `lnx-uspike` (10.110.0.31, swtpm), joined to `mld-ipa-spike` by OTP:

- **Decision: Ubuntu uses `ipa-client-install`, no hand-made join.** `freeipa-client` 4.13.1-1 (universe; `python3-ipaclient` 4.13.1-1, `sssd-ipa` 2.12.0-1ubuntu5.6, `autofs` 5.1.9-1.2ubuntu4, `nfs-common` 1:2.8.5-1ubuntu1, `certmonger` 0.79.21-1). `apt-get install freeipa-client` pulls 52 packages (8.6 MB). `ipa-client-install … --automount-location=default` rc 0 (`Augeas failed to configure file /etc/chrony/chrony.conf`, time sync ok anyway). It writes nsswitch (`passwd/group: files systemd sss`, `automount: sss`, `sudoers: files sss`), pam_sss in `common-{account,auth,password,session}`, `/etc/krb5.conf.d/freeipa*`, `/etc/default/nfs-common`, `/etc/idmapd.conf`, sshd drop-in `04-ipa.conf`. The spike installed it at first boot; whether it works in the autoinstall `packages:` list is not tested (the installed system has universe enabled).
- Ubuntu default ccache from ipa-client-install: `KEYRING:persistent:%{uid}`. With `0-mld-ccache` + sssd conf.d the login ccache is `FILE:/tmp/krb5cc_200004`.
- **Review item M1 confirmed on Ubuntu:** after join `sssd-{autofs,nss,pac,pam,ssh,sudo}.socket` are all `failed` (and stay failed after restart and login). `phase_sssd` must disable all six on Ubuntu (today: nss pam pac).
- Login: nfs4 vers=4.2 `sec=krb5p`, `chmod 755` works, and the home **roams between the Fedora and the Ubuntu client** (alice's `mld-probe` from `lnx-spike` is there; files show `+` = NFSv4 ACL display).
- Machine cert into the TPM token: MONITORING, issuer IPA CA. On Ubuntu `modutil -add mld-tpm2` is needed (NSS does not load tpm2-pkcs11 through p11-kit-proxy as on Fedora); module path `/usr/lib/x86_64-linux-gnu/pkcs11/libtpm2_pkcs11.so`.
- User cert: stuck `NEED_TO_SUBMIT`, because session certmonger state is in `~/.config` on the roaming home: the Fedora client's CA `mld-ipa-user` (helper `/usr/libexec/certmonger/ipa-submit`) was reused; Ubuntu's helper is `/usr/lib/certmonger/ipa-submit`. Confirms the existing rule: session certmonger runs with `HOME=/var/lib/mld-users/%U` (per device). The helper path goes into `distro.sh`.
- Policy from client: host ticket 200.
- AppArmor DENIED lines: only stock profiles (`systemd-detect-virt`, `ubuntu_pro_esm_cache_systemd_detect_virt`, `who` reading `/etc/nsswitch.conf` + `/etc/passwd`), none from the IPA/NFS/certmonger path.
