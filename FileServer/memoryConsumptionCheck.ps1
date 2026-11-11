Get-Process robocopy,powershell,pwsh |
    Select-Object Name, Id,
        @{N='MemoryMB';E={[math]::Round($_.WorkingSet64 / 1MB, 2)}},
        @{N='CPU';E={$_.CPU}} |
    Format-Table -AutoSize
