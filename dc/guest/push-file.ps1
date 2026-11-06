# Runs on the DC as SYSTEM (build.sh guest_run). Needs $Path, $B64 (file content, base64).
# The content can have a BOM already. TrimStart removes it before the write adds one, else PowerShell reads "?#".
if (Test-Path $Path) { (Get-Item $Path).IsReadOnly = $false }
$text = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($B64)).TrimStart([char]0xFEFF)
[IO.File]::WriteAllText($Path, $text, (New-Object Text.UTF8Encoding $true))
