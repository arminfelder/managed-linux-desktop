# Phase 7: certificate templates for autoenrollment, made as a Windows admin makes them (duplicate + Autoenroll).
#   MLD-LinuxComputer: copy of Workstation, subject DNS name from AD, Enroll + Autoenroll for Domain Computers.
#   MLD-LinuxUser:     copy of User as schema version 2, subject + UPN from AD, no e-mail requirement,
#                      Enroll + Autoenroll for the Linux group.
# The Linux client reads these permissions from AD and enrolls the same templates a Windows client would.
# Returns $false.
$ErrorActionPreference = 'Stop'
Import-Module ActiveDirectory

$cfgNc = (Get-ADRootDSE).configurationNamingContext
$pks = "CN=Public Key Services,CN=Services,$cfgNc"
$tplBase = "CN=Certificate Templates,$pks"
$oidBase = "CN=OID,$pks"

$GUID_ENROLL = [guid]'0e10c968-78fb-11d2-90d4-00c04f79dc55'
$GUID_AUTOENROLL = [guid]'a05b8cc2-17bc-4802-a710-e7c15ab866a2'

# Attributes that make a template. Copied from the source, then changed where necessary.
$copyAttrs = 'flags', 'pKIDefaultKeySpec', 'pKIKeyUsage', 'pKIMaxIssuingDepth', 'pKICriticalExtensions',
    'pKIExtendedKeyUsage', 'pKIExpirationPeriod', 'pKIOverlapPeriod', 'pKIDefaultCSPs',
    'msPKI-RA-Signature', 'msPKI-Enrollment-Flag', 'msPKI-Private-Key-Flag', 'msPKI-Certificate-Name-Flag',
    'msPKI-Minimal-Key-Size', 'msPKI-Certificate-Application-Policy'

function New-TemplateOid([string]$name) {
    $forest = (Get-ADObject $oidBase -Properties msPKI-Cert-Template-OID).'msPKI-Cert-Template-OID'
    $rnd = New-Object System.Random
    do {
        $oid = '{0}.{1}.{2}' -f $forest, $rnd.Next(10000000, 99999999), $rnd.Next(10000000, 99999999)
        $cn = '{0}.{1}' -f $rnd.Next(10000000, 99999999), ([guid]::NewGuid().ToString('N').Substring(0, 16)).ToUpper()
    } while (Get-ADObject -SearchBase $oidBase -Filter "msPKI-Cert-Template-OID -eq '$oid'")
    New-ADObject -Path $oidBase -Type msPKI-Enterprise-Oid -Name $cn -OtherAttributes @{
        flags = [int]1; displayName = $name; 'msPKI-Cert-Template-OID' = $oid }
    return $oid
}

# After a restart, CertSvc needs some seconds before its RPC interface answers (RPC_S_SERVER_UNAVAILABLE).
function Wait-CA {
    for ($i = 0; $i -lt 30; $i++) {
        try { Get-CATemplate -ErrorAction Stop | Out-Null; return } catch { Start-Sleep -Seconds 2 }
    }
    throw 'CA does not answer after the restart'
}

function New-LinuxTemplate([string]$name, [string]$source, [string]$group, [hashtable]$change) {
    $dn = "CN=$name,$tplBase"
    # The templates are in the configuration partition: without -SearchBase, Get-ADObject searches the domain.
    if (-not (Get-ADObject -SearchBase $tplBase -SearchScope OneLevel -Filter "cn -eq '$name'")) {
        $src = Get-ADObject "CN=$source,$tplBase" -Properties $copyAttrs
        $attrs = @{}
        foreach ($a in $copyAttrs) { if ($null -ne $src.$a) { $attrs[$a] = $src.$a } }
        foreach ($k in $change.Keys) { $attrs[$k] = $change[$k] }
        # A duplicate is not a default template: clear CT_FLAG_IS_DEFAULT (0x10000), set IS_MODIFIED (0x20000).
        $attrs['flags'] = [int](([int64]$src.flags -band (-bnot [int64]0x10000)) -bor 0x20000)
        $attrs['displayName'] = $name
        $attrs['revision'] = [int]100
        $attrs['msPKI-Template-Schema-Version'] = [int]2
        $attrs['msPKI-Template-Minor-Revision'] = [int]1
        $attrs['msPKI-Cert-Template-OID'] = New-TemplateOid $name
        # Byte arrays (key usage, periods) must be [byte[]]; multi-valued strings must be [string[]].
        foreach ($k in @($attrs.Keys)) {
            $v = $attrs[$k]
            if ($v -is [Microsoft.ActiveDirectory.Management.ADPropertyValueCollection]) {
                if ($v.Count -eq 0) { $attrs.Remove($k); continue }
                $attrs[$k] = if ($v[0] -is [byte]) { [byte[]]@($v) } else { [string[]]@($v) }
            }
        }
        New-ADObject -Path $tplBase -Type pKICertificateTemplate -Name $name -OtherAttributes $attrs
        Write-Host "template $name made from $source"
    }

    $sid = (Get-ADGroup $group).SID
    $acl = Get-Acl "AD:$dn"
    foreach ($right in $GUID_ENROLL, $GUID_AUTOENROLL) {
        $have = $acl.Access | Where-Object { $_.ObjectType -eq $right -and
            ($_.IdentityReference.Translate([Security.Principal.SecurityIdentifier])) -eq $sid }
        if (-not $have) {
            $acl.AddAccessRule((New-Object System.DirectoryServices.ActiveDirectoryAccessRule $sid,
                'ExtendedRight', 'Allow', $right))
        }
    }
    $acl.AddAccessRule((New-Object System.DirectoryServices.ActiveDirectoryAccessRule $sid, 'GenericRead', 'Allow'))
    Set-Acl "AD:$dn" $acl

    # Add-CATemplate checks a local template cache that Windows refreshes late ("does not exist in the domain").
    # Publishing is the certificateTemplates attribute of the CA object, so write it directly if necessary.
    if (-not (Get-CATemplate | Where-Object Name -eq $name)) {
        try { Add-CATemplate -Name $name -Force }
        catch {
            $ca = Get-ADObject "CN=$($Cfg.CaName),CN=Enrollment Services,$pks" -Properties certificateTemplates
            if ($ca.certificateTemplates -notcontains $name) {
                Set-ADObject $ca -Add @{ certificateTemplates = $name }
            }
            Restart-Service CertSvc
            Wait-CA
        }
    }
    if (-not (Get-CATemplate | Where-Object Name -eq $name)) { throw "CA does not publish $name" }
}

# msPKI-Enrollment-Flag 0x20 = CT_FLAG_AUTO_ENROLLMENT.
# msPKI-Certificate-Name-Flag: 0x08000000 SUBJECT_ALT_REQUIRE_DNS, 0x40000000 SUBJECT_REQUIRE_DNS_AS_CN,
#   0x02000000 SUBJECT_ALT_REQUIRE_UPN, 0x80000000 SUBJECT_REQUIRE_DIRECTORY_PATH.
$src = Get-ADObject "CN=Workstation,$tplBase" -Properties msPKI-Enrollment-Flag
New-LinuxTemplate 'MLD-LinuxComputer' 'Workstation' 'Domain Computers' @{
    'msPKI-Enrollment-Flag' = [int]($src.'msPKI-Enrollment-Flag' -bor 0x20)
    'msPKI-Certificate-Name-Flag' = [int]([int64]0x08000000 -bor 0x40000000)
}
New-LinuxTemplate 'MLD-LinuxUser' 'User' $Cfg.LinuxGroup @{
    'msPKI-Enrollment-Flag' = [int]0x29
    # PowerShell reads 0x82000000 as Int32 already (negative). AD stores this attribute as a signed 32-bit value.
    'msPKI-Certificate-Name-Flag' = [int]0x82000000
    'msPKI-Private-Key-Flag' = [int]0x10
}
Write-Host "autoenrollment templates: $((Get-CATemplate | Where-Object Name -like 'MLD-*').Name -join ', ')"
return $false
