# Phase 1: static IP, then promote this server to the forest-root DC of $Cfg.Domain.
# Returns $true: the promotion completes during the reboot.
$ErrorActionPreference = 'Stop'

try { Import-Module ActiveDirectory -ErrorAction Stop; if (Get-ADDomain -ErrorAction Stop) { Write-Host 'AD already installed'; return $false } } catch {}

$nic = Get-NetAdapter -Physical | Where-Object Status -eq 'Up' | Select-Object -First 1
if (-not $nic) { throw 'no connected network adapter (NetKVM driver missing?)' }
if (-not (Get-NetIPAddress -InterfaceIndex $nic.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
          Where-Object IPAddress -eq $Cfg.DcIp)) {
    Get-NetIPAddress -InterfaceIndex $nic.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
    Remove-NetRoute -InterfaceIndex $nic.ifIndex -Confirm:$false -ErrorAction SilentlyContinue
    New-NetIPAddress -InterfaceIndex $nic.ifIndex -IPAddress $Cfg.DcIp -PrefixLength $Cfg.NetPrefix `
        -DefaultGateway $Cfg.NetGw | Out-Null
}
# The forest root must resolve its own zone after the promotion.
Set-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -ServerAddresses '127.0.0.1'

Install-WindowsFeature AD-Domain-Services -IncludeManagementTools | Out-Null

$dsrm = ConvertTo-SecureString $Cfg.DsrmPw -AsPlainText -Force
Install-ADDSForest `
    -DomainName               $Cfg.Domain `
    -DomainNetbiosName        $Cfg.Netbios `
    -SafeModeAdministratorPassword $dsrm `
    -InstallDns `
    -ForestMode $Cfg.AdLevel -DomainMode $Cfg.AdLevel `
    -NoRebootOnCompletion -Force | Out-Null

return $true
