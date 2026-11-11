
$Source = "E:\Shares\Data"
$Destination = "$env:TEMP\RoboDiscoveryTest"
$LogFile = "C:\Temp\RoboDiscovery.log"

New-Item -ItemType Directory -Path "C:\Temp" -Force |
    Out-Null

Remove-Item $LogFile -Force -ErrorAction SilentlyContinue

& "$env:windir\System32\robocopy.exe" `
    $Source `
    $Destination `
    /L /B /E /LEV:1 /FP `
    /R:0 /W:0 /NP /XJ `
    /NJH /NJS `
    "/LOG:$LogFile"

$RoboExitCode = $LASTEXITCODE

Write-Host "`nRobocopy exit code: $RoboExitCode"
Write-Host "Log file: $LogFile"

Write-Host "`n--- RAW ROBOCOPY LOG ---" -ForegroundColor Cyan

Get-Content -LiteralPath $LogFile
