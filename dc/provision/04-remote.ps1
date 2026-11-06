# Phase 4: WinRM and RDP for the lab subnet. Returns $false.
$ErrorActionPreference = 'Stop'

# Negotiate only. Basic auth and unencrypted traffic stay off.
Enable-PSRemoting -Force -SkipNetworkProfileCheck | Out-Null
Set-Item WSMan:\localhost\Service\Auth\Basic $false
Set-Item WSMan:\localhost\Service\AllowUnencrypted $false
Get-NetFirewallRule -DisplayGroup 'Windows Remote Management' |
    Where-Object { $_.Direction -eq 'Inbound' } |
    Set-NetFirewallRule -Profile Any -RemoteAddress LocalSubnet -Enabled True

Set-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0
Get-NetFirewallRule -DisplayGroup 'Remote Desktop' |
    Set-NetFirewallRule -Profile Any -RemoteAddress LocalSubnet -Enabled True
return $false
