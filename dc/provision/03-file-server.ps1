# Phase 3: share Homes$ with one folder per lab user. The AD homeDirectory points to it.
# Returns $false.
$ErrorActionPreference = 'Stop'
Import-Module ActiveDirectory

Install-WindowsFeature FS-FileServer | Out-Null

$root  = $Cfg.HomesPath
$share = 'Homes$'
$dcFqdn = "$($env:COMPUTERNAME).$($Cfg.Domain)".ToLower()
New-Item -ItemType Directory -Path $root -Force | Out-Null

# Users can open only their own folder. "Bypass traverse checking" lets them pass through the root.
function Invoke-Icacls([string[]]$Arguments) {
    $ErrorActionPreference = 'Continue'
    $msg = & icacls.exe @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "icacls $($Arguments -join ' ') failed: $msg" }
}
Invoke-Icacls @($root, '/inheritance:r',
    '/grant:r', '*S-1-5-18:(OI)(CI)F',
    '/grant:r', '*S-1-5-32-544:(OI)(CI)F')

if (-not (Get-SmbShare -Name $share -ErrorAction SilentlyContinue)) {
    New-SmbShare -Name $share -Path $root -FolderEnumerationMode AccessBased `
        -FullAccess 'BUILTIN\Administrators' -ChangeAccess "$($Cfg.Netbios)\Domain Users" `
        -EncryptData ([bool]$Cfg.SmbEncrypt) | Out-Null
}

foreach ($u in $Cfg.LabUsers) {
    $dir = Join-Path $root $u
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Invoke-Icacls @($dir, '/grant:r', "$($Cfg.Netbios)\${u}:(OI)(CI)F")
    Invoke-Icacls @($dir, '/setowner', "$($Cfg.Netbios)\$u")
    Set-ADUser -Identity $u -HomeDirectory "\\$dcFqdn\$share\$u" -HomeDrive 'H:'
}
Write-Host "share \\$dcFqdn\$share ready for $($Cfg.LabUsers -join ', ')"
return $false
