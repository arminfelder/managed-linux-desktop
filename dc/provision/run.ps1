# Resumable provisioning driver. It runs the phases in sequence across reboots.
# The state is the integer in C:\build\phase.
# A boot-triggered scheduled task starts this script again after each reboot.
# Markers for the host: C:\build\DONE on success, C:\build\FAILED on an error.
$ErrorActionPreference = 'Stop'
$ProgressPreference     = 'SilentlyContinue'

$work = 'C:\build'
$prov = "$work\provision"

# NetKVM is not boot-critical, so WinPE does not install it. Phase 1 needs the NIC.
# The guest tools include the qemu guest agent, which is the host control path.
function Install-Virtio {
    $vio = (Get-Volume | Where-Object { $_.DriveLetter -and (Test-Path ($_.DriveLetter + ':\NetKVM')) } |
            Select-Object -First 1).DriveLetter
    if (-not $vio) { return }
    foreach ($drv in 'NetKVM', 'Balloon', 'vioserial', 'vioscsi', 'viostor') {
        $p = "${vio}:\$drv\2k25\amd64"
        if (Test-Path $p) {
            & {
                $ErrorActionPreference = 'Continue'
                pnputil /add-driver "$p\*.inf" /install /subdirs 2>&1 | Out-Null
            }
        }
    }
    $gt = "${vio}:\virtio-win-guest-tools.exe"
    if (Test-Path $gt) { Start-Process $gt -ArgumentList '/quiet', '/norestart' -Wait -ErrorAction SilentlyContinue }
}

function Copy-Provision {
    $srcRoot = (Get-Volume | Where-Object { $_.DriveLetter -and (Test-Path ($_.DriveLetter + ':\provision\run.ps1')) } |
                Select-Object -First 1).DriveLetter + ':\provision'
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    Copy-Item $srcRoot $prov -Recurse -Force
    # Files from the CD keep the ReadOnly attribute. Clear it, so that ./build.sh resume can replace them.
    Get-ChildItem $prov -Recurse -File | ForEach-Object { $_.IsReadOnly = $false }
    Install-Virtio
}

if (-not (Test-Path $prov)) { Copy-Provision }
Start-Transcript -Path "$work\provision.log" -Append | Out-Null
. "$prov\config.ps1"
Remove-Item "$work\FAILED" -Force -ErrorAction SilentlyContinue

# Between Install-ADDSForest and its reboot, no principal works for the resume task.
# The domain account does not resolve yet ("trust relationship ... failed"), and the reboot deletes the local SAM.
# So in that window a second task, build-resume-boot, runs this script as SYSTEM after the reboot.
# It waits until the domain principal registers, then starts build-resume as the domain administrator.
# Phases 2 and 3 change AD objects and ACLs, so they run as the domain administrator, not as SYSTEM.
# Two task names are necessary: /run on the task that is running now is ignored (instance policy IgnoreNew).
# Use schtasks.exe: Register-ScheduledTask fails on a task record that is not consistent and has no -Force.
function Invoke-Schtasks([string[]]$Arguments) {
    # PowerShell 5.1 turns native stderr into a terminating error under 'Stop'. Use the exit code.
    $ErrorActionPreference = 'Continue'
    $msg = & schtasks.exe @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { Write-Host "schtasks $($Arguments[0]) $($Arguments[2]): $msg" }
    return ($LASTEXITCODE -eq 0)
}

# PowerShell 5.1 does not escape '"' in native arguments. Without this, schtasks gets a changed password.
# The argument must not contain white space: then PowerShell adds quotes and the escape is not correct.
function ConvertTo-NativeArg([string]$s) {
    if ($s -match '\s') { throw 'a native argument with white space cannot be escaped reliably' }
    [regex]::Replace($s, '(\\*)"', { param($m) ($m.Groups[1].Value * 2) + '\"' })
}

$resumeCmd = "powershell.exe -ExecutionPolicy Bypass -NoProfile -File $prov\run.ps1"
function Register-Resume([string]$User) {
    Invoke-Schtasks @('/create', '/tn', 'build-resume', '/sc', 'onstart', '/rl', 'highest', '/f',
                      '/tr', $resumeCmd, '/ru', $User, '/rp', (ConvertTo-NativeArg $Cfg.AdminPw))
}

function Ensure-Resume {
    if (-not (Get-CimInstance Win32_ComputerSystem).PartOfDomain) {
        if (-not (Register-Resume 'Administrator')) { throw 'cannot register the resume task' }
        return
    }
    if (Register-Resume "$($Cfg.Netbios)\Administrator") {
        Invoke-Schtasks @('/delete', '/tn', 'build-resume-boot', '/f') | Out-Null
        return
    }
    Write-Host 'domain principal not usable yet: build-resume-boot runs as SYSTEM after the reboot'
    $ok = Invoke-Schtasks @('/create', '/tn', 'build-resume-boot', '/sc', 'onstart', '/rl', 'highest', '/f',
                            '/tr', $resumeCmd, '/ru', 'SYSTEM')
    if (-not $ok) { throw 'cannot register build-resume-boot as SYSTEM' }
}

# Boot path of build-resume-boot. It ends the script.
function Start-DomainResume {
    $deadline = (Get-Date).AddMinutes(20)
    while (-not (Register-Resume "$($Cfg.Netbios)\Administrator")) {
        if ((Get-Date) -ge $deadline) {
            Set-Content -Path "$work\FAILED" -Value 'boot: domain principal did not become usable in 20 min'
            Stop-Transcript | Out-Null
            exit 1
        }
        Start-Sleep -Seconds 15
    }
    Write-Host 'domain principal registered: starting build-resume as the domain administrator'
    if (-not (Invoke-Schtasks @('/run', '/tn', 'build-resume'))) {
        Set-Content -Path "$work\FAILED" -Value 'boot: schtasks /run build-resume failed'
    }
    Invoke-Schtasks @('/delete', '/tn', 'build-resume-boot', '/f') | Out-Null
    Stop-Transcript | Out-Null
    exit 0
}

# Before the domain exists, SYSTEM (dc resume after a phase 0 failure) uses the normal path.
if ([Security.Principal.WindowsIdentity]::GetCurrent().IsSystem -and
    (Get-CimInstance Win32_ComputerSystem).PartOfDomain) {
    Start-DomainResume
}

function Set-Phase($n) { Set-Content -Path "$work\phase" -Value $n }
function Get-Phase     { if (Test-Path "$work\phase") { [int](Get-Content "$work\phase") } else { 0 } }

$phases = @(
    @{ n=1; script='01-install-ad.ps1' },
    @{ n=2; script='02-directory.ps1' },
    @{ n=3; script='03-file-server.ps1' },
    @{ n=4; script='04-remote.ps1' },
    @{ n=5; script='05-export.ps1' },
    @{ n=6; script='06-adcs.ps1' },
    @{ n=7; script='07-templates.ps1' },
    @{ n=8; script='08-linux-gpo.ps1' },
    @{ n=9; script='09-admx.ps1' }
)

# Runs one phase. A reboot request ends the script.
function Invoke-Phase($p) {
    $t0 = Get-Date
    Write-Host "=== PHASE $($p.n): $($p.script) at $($t0.ToUniversalTime().ToString('o')) ==="
    # A phase returns $true as its last output to request a reboot.
    # Other pipeline output must not make the result true.
    $out = @(& "$prov\$($p.script)")
    $reboot = ($out.Count -gt 0) -and ($out[-1] -is [bool]) -and $out[-1]
    $line = "phase $($p.n) $($p.script): {0:N1} min" -f ((Get-Date) - $t0).TotalMinutes
    Write-Host "=== $line ==="
    Add-Content -Path "$work\timing.log" -Value $line
    Set-Phase ($p.n + 1)
    if ($reboot) {
        Write-Host "=== PHASE $($p.n) requests reboot ==="
        # Register again before the reboot. After phase 1 this writes the domain principal.
        Ensure-Resume
        Stop-Transcript | Out-Null
        Restart-Computer -Force
        exit
    }
}

try {
    Ensure-Resume
    $cur = Get-Phase
    if ($cur -eq 0) { $cur = 1; Set-Phase 1 }

    foreach ($p in $phases) {
        if ($p.n -lt $cur) { continue }
        Invoke-Phase $p
    }
} catch {
    $msg = "phase $(Get-Phase): $($_.Exception.Message)"
    Write-Host "=== FAILED $msg ==="
    Write-Host $_.ScriptStackTrace
    Set-Content -Path "$work\FAILED" -Value $msg
    Stop-Transcript | Out-Null
    exit 1
}

Invoke-Schtasks @('/delete', '/tn', 'build-resume', '/f') | Out-Null
Set-Content -Path "$work\DONE" -Value (Get-Date -Format o)
Write-Host '=== PROVISIONING COMPLETE ==='
Stop-Transcript | Out-Null
