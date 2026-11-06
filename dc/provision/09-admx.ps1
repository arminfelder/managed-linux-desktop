# Phase 9: ADMX templates in the central store (SYSVOL\domain\Policies\PolicyDefinitions). Then GPMC shows the
# settings of the Linux GPO by name: Samba (Unix settings, smb.conf), GNOME lock-down, Firefox, Chrome.
# The clients do not need the templates: samba-gpupdate and Windows read only the values in the GPO.
# Returns $false.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Add-Type -AssemblyName System.IO.Compression.FileSystem

$store = Join-Path $env:SystemRoot 'SYSVOL\domain\Policies\PolicyDefinitions'
if (-not (Test-Path $store)) {
    # With a central store, GPMC reads only the central store. The Windows templates must be in it too.
    Copy-Item (Join-Path $env:SystemRoot 'PolicyDefinitions') $store -Recurse
    Write-Host "central store made from $env:SystemRoot\PolicyDefinitions"
}
New-Item -ItemType Directory -Force (Join-Path $store 'en-US') | Out-Null
$tmp = Join-Path $Cfg.Work 'admx'
New-Item -ItemType Directory -Force $tmp | Out-Null

function Get-Download([string]$Url, [string]$Out, [string]$Sha256) {
    Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $Out
    $h = (Get-FileHash $Out -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($Sha256 -and $h -ne $Sha256) { throw "sha256 of $Url is $h, not $Sha256" }
    Write-Host "downloaded $Url (sha256 $h)"
}

function Install-Template([string]$Src, [string]$Rel) {
    $dst = Join-Path $store $Rel
    if ((Test-Path $dst) -and (Get-FileHash $Src).Hash -eq (Get-FileHash $dst).Hash) { return }
    Copy-Item $Src $dst -Force
    Write-Host "installed $Rel"
}

# Copies ZIP entries to the store: @{ 'entry/in/zip.admx' = 'name.admx' }.
function Install-FromZip([string]$Zip, [hashtable]$Entries) {
    $z = [IO.Compression.ZipFile]::OpenRead($Zip)
    try {
        foreach ($k in $Entries.Keys) {
            $e = $z.GetEntry($k)
            if (-not $e) { throw "$k is not in $Zip" }
            $out = Join-Path $tmp ($Entries[$k] -replace '[\\/]', '_')
            [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $out, $true)
            Install-Template $out $Entries[$k]
        }
    } finally { $z.Dispose() }
}

# Samba 4.23.6: the Samba version of the Ubuntu 26.04 client (python3-samba, samba-gpupdate).
$samba = 'https://gitlab.com/samba-team/samba/-/raw/samba-4.23.6/libgpo/admx'
$sambaFiles = [ordered]@{
    'samba.admx'                = '3fbfad818d873dd4a3f86917c404c7ee011e5c0c937b5b039b6ccb8af345d4b4'
    'en-US\samba.adml'          = 'd19909b4fd7ec1c9ef1c32c713c762ea12d1ac9b942225bd70301fecb4e594e8'
    'GNOME_Settings.admx'       = '4d6bdf6551104b20e6ba4c67dfc6e9cda3f07a924a131cefdfe9248cf7da8d26'
    'en-US\GNOME_Settings.adml' = '553e75dadf7f93e210938905e8f0c286a5737dd3f3d2a5b5b7942e51d74fd8c6'
}
foreach ($rel in $sambaFiles.Keys) {
    $out = Join-Path $tmp ($rel -replace '\\', '_')
    Get-Download "$samba/$($rel -replace '\\', '/')" $out $sambaFiles[$rel]
    Install-Template $out $rel
}

# Mozilla policy templates v8.4 (firefox.admx needs mozilla.admx for its category).
$moz = Join-Path $tmp 'mozilla.zip'
Get-Download 'https://github.com/mozilla/policy-templates/releases/download/v8.4/policy_templates_v8.4.zip' $moz `
    '287fb7d5ae5100f0a24c0ec8e025b3dd80a24c001ad7b5c3a91cc2c4616d58ea'
Install-FromZip $moz @{
    'windows/mozilla.admx' = 'mozilla.admx'; 'windows/firefox.admx' = 'firefox.admx'
    'windows/en-US/mozilla.adml' = 'en-US\mozilla.adml'; 'windows/en-US/firefox.adml' = 'en-US\firefox.adml'
}

# Google publishes only the newest templates (124 MB ZIP, the content changes with each Chrome release), so there is
# no fixed sum. The phase downloads them once and checks the content. To update: delete chrome.admx, run dc resume.
if (-not (Test-Path (Join-Path $store 'chrome.admx'))) {
    $g = Join-Path $tmp 'google.zip'
    Get-Download 'https://dl.google.com/dl/edgedl/chrome/policy/policy_templates.zip' $g ''
    Install-FromZip $g @{
        'windows/admx/google.admx' = 'google.admx'; 'windows/admx/chrome.admx' = 'chrome.admx'
        'windows/admx/en-US/google.adml' = 'en-US\google.adml'; 'windows/admx/en-US/chrome.adml' = 'en-US\chrome.adml'
    }
    if (-not (Select-String -Path (Join-Path $store 'chrome.admx') -Pattern 'name="AuthServerAllowlist"' -Quiet)) {
        throw 'chrome.admx has no policy AuthServerAllowlist'
    }
}

Remove-Item $tmp -Recurse -Force
$n = @(Get-ChildItem $store -Filter *.admx).Count
Write-Host "central store $store`: $n ADMX files"
return $false
