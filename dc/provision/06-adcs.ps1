# Phase 6: AD CS enterprise root CA, web enrollment (http://<dc>/certsrv), templates Machine and User.
# DCOM enrollment (ICertRequestD) needs no extra setup: the CA role opens it. Returns $false.
# Install-AdcsCertificationAuthority for an enterprise CA needs Enterprise Admins: run as the domain administrator.
$ErrorActionPreference = 'Stop'
Import-Module ActiveDirectory

# The built-in User template puts the e-mail address into the subject. Without 'mail' the CA denies the request.
foreach ($u in $Cfg.LabUsers) {
    Set-ADUser -Identity $u -EmailAddress "$u@$($Cfg.Domain)"
}

Install-WindowsFeature ADCS-Cert-Authority, ADCS-Web-Enrollment -IncludeManagementTools | Out-Null

if (-not (Get-Service CertSvc -ErrorAction SilentlyContinue) -or
    -not (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration')) {
    Install-AdcsCertificationAuthority -CAType EnterpriseRootCA -CACommonName $Cfg.CaName `
        -KeyLength 3072 -HashAlgorithmName SHA256 -ValidityPeriod Years -ValidityPeriodUnits 10 -Force | Out-Null
}
try { Install-AdcsWebEnrollment -Force | Out-Null }
catch { if ($_.Exception.Message -notmatch 'already') { throw } }

Start-Service CertSvc
foreach ($t in 'Machine', 'User') {
    if (-not (Get-CATemplate | Where-Object Name -eq $t)) { Add-CATemplate -Name $t -Force }
}

# Install-AdcsWebEnrollment sets "Require SSL" on /certsrv (403.4 over http), but adds no https binding.
# The server certificate is the DC's own autoenrolled certificate (DomainController/KerberosAuthentication:
# DNS name, server authentication). A request into LocalMachine\My runs as DC1$, which may not enroll
# WebServer (CERTSRV_E_TEMPLATE_DENIED). certutil -pulse starts the DC autoenrollment now.
Import-Module WebAdministration
$fqdn = "$env:COMPUTERNAME.$($Cfg.Domain)".ToLower()
function Find-ServerCert {
    Get-ChildItem Cert:\LocalMachine\My | Where-Object {
        $_.DnsNameList.Unicode -contains $fqdn -and $_.Issuer -match [regex]::Escape($Cfg.CaName) -and
        $_.EnhancedKeyUsageList.ObjectId -contains '1.3.6.1.5.5.7.3.1' -and $_.NotAfter -gt (Get-Date) } |
        Sort-Object NotAfter -Descending | Select-Object -First 1
}
$cert = Find-ServerCert
for ($i = 0; -not $cert -and $i -lt 30; $i++) {
    if ($i % 6 -eq 0) { & certutil.exe -pulse | Out-Null }
    Start-Sleep -Seconds 10
    $cert = Find-ServerCert
}
if (-not $cert) { throw "no autoenrolled server certificate for $fqdn after 5 min" }
if (-not (Get-WebBinding -Name 'Default Web Site' -Protocol https)) {
    New-WebBinding -Name 'Default Web Site' -Protocol https -Port 443
}
Get-Item IIS:\SslBindings\0.0.0.0!443 -ErrorAction SilentlyContinue | Remove-Item
New-Item IIS:\SslBindings\0.0.0.0!443 -Value $cert | Out-Null
Write-Host "certsrv: https://$fqdn/certsrv/ with $($cert.Thumbprint)"

# A DC can start with the Public network profile: NLA ran before AD DS. Then Domain-profile firewall rules
# (for example the CA DCOM rules) do not apply. Delayed start lets NLA find the domain at boot.
& sc.exe config NlaSvc start= delayed-auto | Out-Null
if ((Get-NetConnectionProfile).NetworkCategory -ne 'DomainAuthenticated') {
    Restart-Service NlaSvc -Force
    Start-Sleep -Seconds 15
}
Write-Host "network profile: $((Get-NetConnectionProfile).NetworkCategory -join ', ')"
Write-Host "CA $($Cfg.CaName): templates $((Get-CATemplate).Name -join ', ')"
return $false
