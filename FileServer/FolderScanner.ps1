
# ============================================================
# Robocopy Folder Scanner - Diagnostic Version
# Backup mode / No copying / Hierarchical JSON
# ============================================================

$Root       = "E:\Shares\Data"
$MaxDepth   = 3
$JsonOutput = "C:\Temp\FolderReport.json"

$Robocopy = "$env:windir\System32\robocopy.exe"

# ------------------------------------------------------------
# Logging
# ------------------------------------------------------------

$Log = [System.Collections.Generic.List[string]]::new()

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )

    $Entry = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] $Message"
    $Log.Add($Entry)

    $Color = switch ($Level) {
        "ERROR"   { "Red" }
        "WARNING" { "Yellow" }
        default   { "Gray" }
    }

    Write-Host $Entry -ForegroundColor $Color
}

# ------------------------------------------------------------
# Run Robocopy and capture everything
# ------------------------------------------------------------

function Invoke-RoboCommand {
    param(
        [string]$Source,
        [string[]]$Options
    )

    try {
        if (!(Test-Path -LiteralPath $Robocopy -PathType Leaf)) {
            throw "Robocopy executable not found: $Robocopy"
        }

        # Unique destination for each dry-run operation.
        # Robocopy /L never creates or copies into it.
        $Destination = Join-Path $env:TEMP (
            "RoboSize_" + [guid]::NewGuid().ToString("N")
        )

        $Output = & $Robocopy $Source $Destination @Options 2>&1
        $ExitCode = $LASTEXITCODE

        $Lines = @(
            $Output | ForEach-Object { $_.ToString() }
        )

        [PSCustomObject]@{
            ExitCode = $ExitCode
            Lines    = $Lines
            Success  = ($ExitCode -lt 8)
            Error    = if ($ExitCode -ge 8) {
                "Robocopy failed with exit code $ExitCode"
            } else { $null }
        }
    }
    catch {
        [PSCustomObject]@{
            ExitCode = -1
            Lines    = @($_.Exception.Message)
            Success  = $false
            Error    = $_.Exception.Message
        }
    }
}

# ------------------------------------------------------------
# Parse numeric summary values
# ------------------------------------------------------------

function Get-RoboSummaryValue {
    param(
        [string[]]$Lines,
        [string]$Label
    )

    $Line = $Lines |
        Where-Object {
            $_ -match "^\s*$Label\s*:"
        } |
        Select-Object -First 1

    if ($Line -match ':\s*([\d,]+)') {
        return [long]($Matches[1] -replace ',', '')
    }

    return $null
}

# ------------------------------------------------------------
# Folder statistics
# ------------------------------------------------------------

function Get-RoboSummary {
    param([string]$Path)

    $Result = Invoke-RoboCommand -Source $Path -Options @(
        "/L", "/B", "/E", "/BYTES",
        "/R:0", "/W:0", "/NFL", "/NDL",
        "/NJH", "/NP", "/XJ"
    )

    $Files = Get-RoboSummaryValue $Result.Lines "Files"
    $Dirs  = Get-RoboSummaryValue $Result.Lines "Dirs"
    $Bytes = Get-RoboSummaryValue $Result.Lines "Bytes"

    $Failed = $null

    $FileLine = $Result.Lines |
        Where-Object { $_ -match '^\s*Files\s*:' } |
        Select-Object -First 1

    if ($FileLine -match '^\s*Files\s*:\s*([\d,]+)\s+([\d,]+)\s+([\d,]+)\s+([\d,]+)\s+([\d,]+)') {
        $Failed = [long]($Matches[5] -replace ',', '')
    }

    $ParseErrors = @()

    if ($null -eq $Files) {
        $ParseErrors += "Could not parse Files summary."
    }

    if ($null -eq $Dirs) {
        $ParseErrors += "Could not parse Dirs summary."
    }

    if ($null -eq $Bytes) {
        $ParseErrors += "Could not parse Bytes summary."
    }

    $Errors = @()

    if ($Result.Error) {
        $Errors += $Result.Error
    }

    $Errors += $ParseErrors

    [PSCustomObject]@{
        Files      = $Files
        Dirs       = $Dirs
        Bytes      = $Bytes
        Failed     = $Failed
        ExitCode   = $Result.ExitCode
        Errors     = $Errors
        RawOutput  = if ($Errors.Count -gt 0) {
            $Result.Lines
        } else { @() }
        Success    = ($Result.Success -and $ParseErrors.Count -eq 0)
    }
}

# ------------------------------------------------------------
# Discover immediate child folders
# ------------------------------------------------------------

function Get-RoboChildDirectories {
    param([string]$Path)

    Write-Log "Discovering subfolders: $Path"

    $Result = Invoke-RoboCommand -Source $Path -Options @(
        "/L", "/B", "/E", "/LEV:1",
        "/FP", "/R:0", "/W:0",
        "/NJH", "/NJS", "/NP", "/XJ"
    )

    $Directories = [System.Collections.Generic.List[string]]::new()

    $EscapedRoot = [regex]::Escape($Path.TrimEnd('\'))

    foreach ($Line in $Result.Lines) {

        # Find full paths rooted under the source directory.
        # This avoids relying on English "New Dir" labels.

        $Pattern = "(?i)(?:^|\s{2,})" +
                   $EscapedRoot +
                   "\\([^\\]+)\\?\s*$"

        if ($Line -match $Pattern) {

            $ChildPath = Join-Path $Path $Matches[1]

            if ($ChildPath -ne $Path) {
                $Directories.Add($ChildPath)
            }
        }
    }

    $UniqueDirectories = @(
        $Directories | Sort-Object -Unique
    )

    [PSCustomObject]@{
        Directories = $UniqueDirectories
        ExitCode    = $Result.ExitCode
        Success     = $Result.Success
        Errors      = if ($Result.Error) {
            @($Result.Error)
        } elseif (!$UniqueDirectories.Count -and $Result.Success) {
            @("No subfolders detected. Check raw Robocopy output.")
        } else {
            @()
        }
        RawOutput   = if (!$UniqueDirectories.Count) {
            $Result.Lines
        } else { @() }
    }
}

# ------------------------------------------------------------
# Format file size
# ------------------------------------------------------------

function Format-Size {
    param([long]$Bytes)

    if ($Bytes -ge 1TB) {
        "{0:N2} TB" -f ($Bytes / 1TB)
    }
    elseif ($Bytes -ge 1GB) {
        "{0:N2} GB" -f ($Bytes / 1GB)
    }
    elseif ($Bytes -ge 1MB) {
        "{0:N2} MB" -f ($Bytes / 1MB)
    }
    elseif ($Bytes -ge 1KB) {
        "{0:N2} KB" -f ($Bytes / 1KB)
    }
    else {
        "$Bytes Bytes"
    }
}

# ------------------------------------------------------------
# Recursive folder scanning
# ------------------------------------------------------------

function New-FolderNode {
    param(
        [string]$Path,
        [int]$Depth
    )

    Write-Log "Scanning folder: $Path"

    $Stats = Get-RoboSummary -Path $Path

    $Children = [System.Collections.Generic.List[object]]::new()
    $Errors = [System.Collections.Generic.List[string]]::new()

    foreach ($ErrorMessage in $Stats.Errors) {
        $Errors.Add($ErrorMessage)
    }

    $DiscoveryExitCode = $null

    if ($Depth -lt $MaxDepth) {

        $Discovery = Get-RoboChildDirectories -Path $Path

        $DiscoveryExitCode = $Discovery.ExitCode

        foreach ($ErrorMessage in $Discovery.Errors) {
            $Errors.Add("Discovery: $ErrorMessage")
        }

        foreach ($ChildPath in $Discovery.Directories) {

            $ChildNode = New-FolderNode `
                -Path $ChildPath `
                -Depth ($Depth + 1)

            $Children.Add($ChildNode)
        }
    }

    $Status = if (!$Stats.Success) {
        "Failed"
    }
    elseif ($Errors.Count -gt 0 -or
            $Stats.Failed -gt 0 -or
            @($Children | Where-Object {
                $_.ScanStatus -ne "Success"
            }).Count -gt 0) {
        "Warning"
    }
    else {
        "Success"
    }

    [PSCustomObject][ordered]@{
        Name               = Split-Path $Path -Leaf
        FullPath           = $Path
        Depth              = $Depth
        SizeBytes          = $Stats.Bytes
        Size               = if ($null -ne $Stats.Bytes) {
            Format-Size $Stats.Bytes
        } else { $null }
        FileCount          = $Stats.Files
        DirCount           = $Stats.Dirs
        FailedFiles        = $Stats.Failed
        ExitCode           = $Stats.ExitCode
        DiscoveryExitCode  = $DiscoveryExitCode
        ScanStatus         = $Status
        Errors             = @($Errors)
        RawOutput          = $Stats.RawOutput
        Children           = $Children
    }
}

# ------------------------------------------------------------
# Main
# ------------------------------------------------------------

try {

    Write-Log "Starting scan: $Root"

    if (!(Test-Path -LiteralPath $Root -PathType Container)) {
        throw "Root folder does not exist or is inaccessible: $Root"
    }

    $Root = (Resolve-Path -LiteralPath $Root -ErrorAction Stop).Path

    $Tree = New-FolderNode -Path $Root -Depth 0

    $Report = [PSCustomObject][ordered]@{
        GeneratedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        Root        = $Root
        MaxDepth    = $MaxDepth
        Tree        = $Tree
        Log         = @($Log)
    }

    $OutputDirectory = Split-Path $JsonOutput -Parent

    if (!(Test-Path -LiteralPath $OutputDirectory)) {
        New-Item -ItemType Directory -Path $OutputDirectory -Force `
            -ErrorAction Stop | Out-Null
    }

    $Json = $Report | ConvertTo-Json -Depth 100

    Set-Content -LiteralPath $JsonOutput -Value $Json `
        -Encoding UTF8 -ErrorAction Stop

    Write-Log "Scan completed: $JsonOutput"

}
catch {

    Write-Log $_.Exception.Message "ERROR"

    throw
}
