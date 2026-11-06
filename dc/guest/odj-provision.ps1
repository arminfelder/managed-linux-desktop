# Runs on the DC as SYSTEM (build.sh guest_run). Needs $Machine and $Replace ('1' or '0').
# Offline domain join, as for Windows clients: djoin makes the computer account in the Linux OU and a blob with its
# password. The client applies the blob (net offlinejoin requestodj) and needs no join password.
# Windows blocks the reuse of an account that an other user made (KB5020276, 0xaac "Re-using the account was blocked
# by security policy"): for example an account from an earlier realm join. $Replace = '1' deletes the existing account
# first (a new device with the same name), but only in the Linux OU.
# Prints the blob as base64 on one line. The file on the DC is deleted.
$ErrorActionPreference = 'Stop'
$dom = Get-ADDomain
$ou = "OU=Computers,OU=Linux,$($dom.DistinguishedName)"
$dir = 'C:\build\odj'
New-Item -ItemType Directory -Force $dir | Out-Null
$file = Join-Path $dir "$Machine.txt"
$old = Get-ADComputer -Filter "Name -eq '$Machine'"
if ($old) {
    if ($Replace -ne '1') { throw "computer account $Machine exists ($($old.DistinguishedName)). To make a new one: client odj --replace" }
    if ($old.DistinguishedName -notlike "*,$ou") { throw "computer account $Machine is not in $ou ($($old.DistinguishedName)): not deleted" }
    Remove-ADObject -Identity $old.DistinguishedName -Recursive -Confirm:$false
    Write-Warning "deleted the old computer account $($old.DistinguishedName)"
}
Remove-Item $file -ErrorAction SilentlyContinue
$out = & djoin.exe /provision /domain $dom.DNSRoot /machine $Machine /machineou $ou /savefile $file 2>&1
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $file)) { throw "djoin /provision $Machine failed: $($out -join ' ')" }
# djoin leaves msDS-SupportedEncryptionTypes empty (a Windows client sets it at its first boot). Empty means RC4 for
# tickets to this account, and the Linux client refuses RC4 ("Encryption type not permitted" in sssd krb5_child).
Set-ADComputer -Identity $Machine -KerberosEncryptionType AES256
try { [Convert]::ToBase64String([IO.File]::ReadAllBytes($file)) } finally { Remove-Item $file -Force }
