$Source = "E:\Shares\Data"
$LogFile = "C:\Temp\RoboDiscovery.log"

& robocopy.exe $Source "$env:TEMP\RoboDiscoveryTest" `
    /L /B /E /LEV:2 /FP `
    /R:0 /W:0 /NP /XJ `
    /NJH /NJS `
    "/LOG:$LogFile"

Get-Content $LogFile
