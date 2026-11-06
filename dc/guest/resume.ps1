# Runs on the DC as SYSTEM (build.sh guest_run). Needs $Work. Starts run.ps1 again after FAILED or for a new phase.
# DONE goes too: a new phase (for example 6, AD CS) runs on a DC that was DONE.
Remove-Item "$Work\FAILED","$Work\DONE" -Force -ErrorAction SilentlyContinue
schtasks.exe /query /tn build-resume 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) { schtasks.exe /run /tn build-resume; exit $LASTEXITCODE }
# If phase 0 failed, build-resume does not exist. Then a one-time task starts run.ps1 as SYSTEM.
schtasks.exe /create /tn build-resume-once /sc once /st 00:00 /ru SYSTEM /rl highest /f /tr "powershell.exe -ExecutionPolicy Bypass -NoProfile -File $Work\provision\run.ps1" 2>&1 | Out-Null
schtasks.exe /run /tn build-resume-once; exit $LASTEXITCODE
