# Runs on the DC as SYSTEM (build.sh guest_run).
# Needs $AdminPw, $LabUsers (space-separated), $LabUserPw, $JoinUser, $JoinPw.
$ErrorActionPreference = 'Stop'
Import-Module ActiveDirectory
function S([string]$p) { ConvertTo-SecureString $p -AsPlainText -Force }
Set-ADAccountPassword -Identity Administrator -Reset -NewPassword (S $AdminPw)
foreach ($u in ($LabUsers -split '\s+' | Where-Object { $_ })) {
    Set-ADAccountPassword -Identity $u -Reset -NewPassword (S $LabUserPw)
}
Set-ADAccountPassword -Identity $JoinUser -Reset -NewPassword (S $JoinPw)
# Auto-logon and the resume tasks use the old administrator password. Provisioning is DONE, so remove them.
$winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
Set-ItemProperty $winlogon -Name AutoAdminLogon -Value '0'
Remove-ItemProperty $winlogon -Name DefaultPassword -ErrorAction SilentlyContinue
# Under 'Stop', PowerShell 5.1 turns schtasks stderr (task not found) into a terminating error.
& {
    $ErrorActionPreference = 'Continue'
    foreach ($t in 'build-resume', 'build-resume-boot', 'build-resume-once') {
        schtasks.exe /delete /tn $t /f 2>&1 | Out-Null
    }
}
'passwords set'
