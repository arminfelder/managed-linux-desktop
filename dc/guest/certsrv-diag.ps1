# Runs on the DC as SYSTEM (build.sh guest_run). certsrv: HTTP status and IIS substatus, SSL, Windows auth, firewall.
Import-Module WebAdministration
try { 'status: ' + (Invoke-WebRequest -UseBasicParsing http://localhost/certsrv/ -UseDefaultCredentials).StatusCode }
catch {
    'status: ' + [int]$_.Exception.Response.StatusCode
    $_.ErrorDetails.Message -split "`n" | Select-String '40\d\.\d+|Error Code|HTTP Error' | Select-Object -First 3
}
$loc = 'Default Web Site/CertSrv'
'sslFlags: ' + (Get-WebConfigurationProperty -PSPath IIS:\ -Location $loc -Name sslFlags `
    -Filter system.webServer/security/access)
'windowsAuth: ' + (Get-WebConfigurationProperty -PSPath IIS:\ -Location $loc -Name enabled `
    -Filter system.webServer/security/authentication/windowsAuthentication).Value
'bindings: ' + ((Get-WebBinding -Name 'Default Web Site' |
    ForEach-Object { $_.protocol + ' ' + $_.bindingInformation }) -join ', ')
Get-NetFirewallRule | Where-Object { $_.DisplayName -match 'World Wide Web|HTTP' } |
    ForEach-Object { 'fw: ' + $_.DisplayName + ' enabled=' + $_.Enabled + ' profile=' + $_.Profile }
Get-NetConnectionProfile | ForEach-Object { 'net: ' + $_.InterfaceAlias + ' ' + $_.NetworkCategory }
