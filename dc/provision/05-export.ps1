# Phase 5: write the domain facts to C:\build\identity.json for the host. Returns $false.
$ErrorActionPreference = 'Stop'
Import-Module ActiveDirectory

$d = Get-ADDomain
[ordered]@{
    domain  = $d.DNSRoot
    netbios = $d.NetBIOSName
    sid     = $d.DomainSID.Value
    dc      = "$($env:COMPUTERNAME).$($d.DNSRoot)".ToLower()
    users   = @($Cfg.LabUsers)
} | ConvertTo-Json -Compress | Set-Content -Path "$($Cfg.Work)\identity.json" -Encoding ASCII
Write-Host "identity: $($d.DNSRoot) $($d.DomainSID.Value)"
return $false
