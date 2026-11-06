# Runs on the DC as SYSTEM (build.sh guest_run). Needs $Work. Facts for build.sh dc verify as JSON.
. "$Work\provision\config.ps1"
Import-Module ActiveDirectory
$d = Get-ADDomain
$s = Get-SmbShare -Name 'Homes$' -ErrorAction SilentlyContinue
$users = @($Cfg.LabUsers | ForEach-Object {
    $u = Get-ADUser $_ -Properties HomeDirectory, MemberOf
    $dir = Join-Path $Cfg.HomesPath $_
    [ordered]@{ name = $_; home = [string]$u.HomeDirectory; dir = (Test-Path $dir);
                owner = if (Test-Path $dir) { (Get-Acl $dir).Owner } else { '' };
                linux = [bool]($u.MemberOf -match "^CN=$($Cfg.LinuxGroup),") } })
& { $ErrorActionPreference = 'Continue'; dcdiag.exe /q 2>&1 | Out-Null }
$dcdiag = $LASTEXITCODE
$srv = [bool](Resolve-DnsName -Type SRV "_ldap._tcp.$($Cfg.Domain)" -ErrorAction SilentlyContinue)
$ca = [string](Get-Service CertSvc -ErrorAction SilentlyContinue).Status
$tpl = @(try { (Get-CATemplate -ErrorAction Stop).Name } catch { })
# certsrv answers 401 (Negotiate) without credentials.
$fq = "$env:COMPUTERNAME.$($Cfg.Domain)".ToLower()
$web = try { (Invoke-WebRequest -UseBasicParsing "https://$fq/certsrv/").StatusCode } catch { [int]$_.Exception.Response.StatusCode }
$net = @((Get-NetConnectionProfile).NetworkCategory | ForEach-Object { [string]$_ })
$store = Join-Path $env:SystemRoot 'SYSVOL\domain\Policies\PolicyDefinitions'
$admx = @('samba', 'GNOME_Settings', 'firefox', 'mozilla', 'chrome', 'google', 'windows' | Where-Object {
    (Test-Path (Join-Path $store "$_.admx")) -and (Test-Path (Join-Path $store "en-US\$_.adml")) })
[ordered]@{ domain = $d.DNSRoot; share = [bool]$s; encrypt = [bool]$s.EncryptData;
            users = $users; dcdiag = $dcdiag; srv = $srv; ca = $ca; templates = $tpl; web = $web; net = $net; admx = $admx } | ConvertTo-Json -Compress -Depth 4
