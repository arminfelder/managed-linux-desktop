# Phase 8: GPO "MLD Linux Clients" on OU=Computers,OU=Linux. The Linux clients apply it with samba-gpupdate.
#   Chrome:  AuthServerAllowlist = *.<domain>           (Kerberos/Negotiate to the domain servers)
#   Firefox: Authentication.SPNEGO = [.<domain>]        (the same for Firefox)
#            SecurityDevices.Add.p11-kit-trust          (Firefox trusts the system store,
#                                                        with the AD CAs from mld-cert ca)
# The values go into Registry.pol directly (Set-GPRegistryValue). The Google and Mozilla ADMX files are only necessary
# to show the settings by name in the GPMC editor.
# Returns $false.
$ErrorActionPreference = 'Stop'
if (-not (Get-WindowsFeature GPMC).Installed) { Install-WindowsFeature GPMC | Out-Null }
Import-Module GroupPolicy
Import-Module ActiveDirectory

$name = 'MLD Linux Clients'
$domain = $Cfg.Domain.ToLowerInvariant()
$ou = "OU=Computers,OU=Linux,$((Get-ADDomain).DistinguishedName)"

$gpo = $null
try { $gpo = Get-GPO -Name $name -ErrorAction Stop } catch { }
if (-not $gpo) {
    $gpo = New-GPO -Name $name -Comment 'Linux clients (samba-gpupdate): browser settings. Made by build.sh, phase 8.'
    Write-Host "GPO '$name' made: $($gpo.Id)"
}

$values = @(
    @{ Key = 'HKLM\Software\Policies\Google\Chrome'; Name = 'AuthServerAllowlist'; Value = "*.$domain" },
    @{ Key = 'HKLM\Software\Policies\Mozilla\Firefox\Authentication\SPNEGO'; Name = '1'; Value = ".$domain" },
    @{ Key = 'HKLM\Software\Policies\Mozilla\Firefox\SecurityDevices\Add'; Name = 'p11-kit-trust';
       Value = '/usr/lib/x86_64-linux-gnu/pkcs11/p11-kit-trust.so' }
)
foreach ($v in $values) {
    # Set-GPRegistryValue increases the GPO version at each call. Write only a changed value.
    $cur = $null
    try { $cur = Get-GPRegistryValue -Name $name -Key $v.Key -ValueName $v.Name -ErrorAction Stop } catch { }
    if ($cur -and $cur.Value -eq $v.Value) { continue }
    Set-GPRegistryValue -Name $name -Key $v.Key -ValueName $v.Name -Type String -Value $v.Value | Out-Null
    Write-Host "set $($v.Key)\$($v.Name) = $($v.Value)"
}

if (-not ((Get-GPInheritance -Target $ou).GpoLinks | Where-Object DisplayName -eq $name)) {
    New-GPLink -Name $name -Target $ou -LinkEnabled Yes | Out-Null
    Write-Host "GPO '$name' linked to $ou"
}
$version = (Get-GPO -Name $name).Computer.DSVersion
$links = ((Get-GPInheritance -Target $ou).GpoLinks.DisplayName) -join ', '
Write-Host "GPO '$name': version $version, links: $links"
return $false
