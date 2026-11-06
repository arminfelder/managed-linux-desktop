# Phase 2: DNS, time source, OUs, lab users, the Linux group and the delegated join account.
# Returns $false.
$ErrorActionPreference = 'Stop'
Import-Module ActiveDirectory

# After the promotion reboot, AD Web Services (tcp/9389) can need minutes to start.
$adDeadline = (Get-Date).AddMinutes(20)
while ($true) {
    try { $dom = Get-ADDomain -ErrorAction Stop; break }
    catch {
        if ((Get-Date) -ge $adDeadline) { throw "AD Web Services did not become available: $_" }
        Write-Host 'waiting for AD Web Services (tcp/9389) ...'
        Start-Sleep -Seconds 15
    }
}
$dn  = $dom.DistinguishedName

if ($Cfg.DnsForwarders) { Set-DnsServerForwarder -IPAddress $Cfg.DnsForwarders | Out-Null }

# sssd updates the PTR record of the client. Without a reverse zone, the update fails.
$rev = $Cfg.ReverseZone
if (-not (Get-DnsServerZone -Name $rev -ErrorAction SilentlyContinue)) {
    Add-DnsServerPrimaryZone -NetworkId $Cfg.NetworkId -ReplicationScope Forest -DynamicUpdate Secure
}

# The forest-root DC is the time source of the domain. Kerberos rejects more than 5 min skew.
# 0x8 = client mode. If the servers cannot be reached, the clock stays on the hypervisor clock.
if ($Cfg.NtpServers) {
    $peers = ($Cfg.NtpServers | ForEach-Object { "$_,0x8" }) -join ' '
    & {
        $ErrorActionPreference = 'Continue'
        w32tm.exe /config "/manualpeerlist:$peers" /syncfromflags:manual /reliable:yes /update 2>&1 | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "w32tm /config failed ($LASTEXITCODE)" }
        Restart-Service w32time
        w32tm.exe /resync /nowait 2>&1 | Out-Host
    }
}

function Ensure-OU([string]$Name, [string]$Path) {
    $ou = "OU=$Name,$Path"
    if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$ou'")) {
        New-ADOrganizationalUnit -Name $Name -Path $Path -ProtectedFromAccidentalDeletion $false
    }
    return $ou
}
$linux     = Ensure-OU 'Linux' $dn
$ouComp    = Ensure-OU 'Computers' $linux
$ouUsers   = Ensure-OU 'Users' $linux
$ouGroups  = Ensure-OU 'Groups' $linux

if (-not (Get-ADGroup -Filter "Name -eq '$($Cfg.LinuxGroup)'")) {
    New-ADGroup -Name $Cfg.LinuxGroup -GroupScope Global -GroupCategory Security -Path $ouGroups
}

$userPw = ConvertTo-SecureString $Cfg.LabUserPw -AsPlainText -Force
foreach ($u in $Cfg.LabUsers) {
    if (-not (Get-ADUser -Filter "SamAccountName -eq '$u'")) {
        New-ADUser -Name $u -SamAccountName $u -UserPrincipalName "$u@$($Cfg.Domain)" `
            -AccountPassword $userPw -Enabled $true -PasswordNeverExpires $true -Path $ouUsers
    }
    Add-ADGroupMember -Identity $Cfg.LinuxGroup -Members $u
}

$joinPw = ConvertTo-SecureString $Cfg.JoinPw -AsPlainText -Force
if (-not (Get-ADUser -Filter "SamAccountName -eq '$($Cfg.JoinUser)'")) {
    New-ADUser -Name $Cfg.JoinUser -SamAccountName $Cfg.JoinUser -AccountPassword $joinPw `
        -Enabled $true -PasswordNeverExpires $true -CannotChangePassword $true -Path $ouUsers
}

# adcli creates the computer object, sets its password, and writes SPNs and dNSHostName.
# CCDC = create and delete child objects of class computer. GA on computer objects = full control of them only.
$who = "$($Cfg.Netbios)\$($Cfg.JoinUser)"
foreach ($grant in @(@('/I:T', "${who}:CCDC;computer"), @('/I:S', "${who}:GA;;computer"))) {
    & {
        $ErrorActionPreference = 'Continue'
        $msg = dsacls.exe $ouComp $grant[0] /G $grant[1] 2>&1
        if ($LASTEXITCODE -ne 0) { throw "dsacls $($grant -join ' ') failed: $msg" }
    }
}
Write-Host "join account $who delegated on $ouComp"
return $false
