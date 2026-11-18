# Runs on the DC as SYSTEM (build.sh guest_run). Needs $Work. Provisioning state as JSON for build.sh dc wait.
function Marker([string]$name) { if (Test-Path "$Work\$name") { (Get-Content "$Work\$name" -Raw).Trim() } else { '' } }
[ordered]@{
    phase  = Marker 'phase'
    done   = Marker 'DONE'
    failed = Marker 'FAILED'
    utc    = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
} | ConvertTo-Json -Compress
