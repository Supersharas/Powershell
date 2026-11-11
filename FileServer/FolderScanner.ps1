
# ============================================================
# ROBOCOPY FOLDER SIZE SCANNER
#
# - Backup mode (/B)
# - List only (/L) - no files copied
# - Hierarchical JSON output
# - Individual Robocopy logs
# - Master execution log
# - Configurable folder depth
# ============================================================

# ---------------- CONFIGURATION -----------------------------

$Root       = "E:\Shares\Data"
$MaxDepth   = 3

$OutputDir  = "C:\Temp\RoboSizeReport"
$JsonOutput = Join-Path $OutputDir "FolderReport.json"
$MasterLog  = Join-Path $OutputDir "Execution.log"
$RoboLogDir = Join-Path $OutputDir "RobocopyLogs"

$Robocopy = "$env:windir\System32\robocopy.exe"

# ---------------- INITIALISATION ----------------------------

New-Item -ItemType Directory -Path $OutputDir -Force |
    Out-Null

New-Item -ItemType Directory -Path $RoboLogDir -Force |
    Out-Null

$script:LogEntries = [System.Collections.Generic.List[string]]::new()
$script:ScanCounter = 0

# ---------------- MASTER LOGGING ----------------------------

function Write-Log {

    param(
        [string]$Message,
        [string]$Level = "INFO"
    )

    $Entry = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] $Message"

    $script:LogEntries.Add($Entry)

    Add-Content -LiteralPath $MasterLog -Value $Entry

    $Color = switch ($Level) {
        "ERROR"   { "Red" }
        "WARNING" { "Yellow" }
        default   { "Gray" }
    }

    Write-Host $Entry -ForegroundColor $Color
}

# ---------------- LOG FILE NAMING ---------------------------

function New-RoboLogName {

    param(
        [string]$Type,
        [string]$Path
    )

    $script:ScanCounter++

    $SafeName = Split-Path $Path -Leaf

    $SafeName = $SafeName -replace '[^a-zA-Z0-9_-]', '_'

    return Join-Path $RoboLogDir (
        "{0:D5}_{1}_{2}.log" -f
        $script:ScanCounter,
        $SafeName,
        $Type
    )
}

# ---------------- ROBOCOPY EXECUTION ------------------------

function Invoke-RoboCommand {

    param(
        [string]$Source,
        [string[]]$Options,
        [string]$LogType
    )

    $LogFile = New-RoboLogName `
        -Type $LogType `
        -Path $Source

    try {

        if (!(Test-Path -LiteralPath $Robocopy -PathType Leaf)) {
            throw "Robocopy executable not found: $Robocopy"
        }

        $Arguments = @(
            $Source
            "$env:TEMP\RoboSize_Dummy"
        ) + $Options + @(
            "/LOG:$LogFile"
        )

        & $Robocopy @Arguments

        $ExitCode = $LASTEXITCODE

        if (Test-Path -LiteralPath $LogFile) {

            $Lines = @(
                Get-Content -LiteralPath $LogFile -ErrorAction Stop
            )

        }
        else {

            $Lines = @()
        }

        $Success = ($ExitCode -ge 0 -and $ExitCode -lt 8)

        [PSCustomObject]@{
            ExitCode = $ExitCode
            Success  = $Success
            LogFile  = $LogFile
            Lines    = $Lines
            Error    = if (!$Success) {
                "Robocopy returned exit code $ExitCode"
            } else { $null }
        }

    }
    catch {

        Write-Log "Robocopy execution failed for $Source : $($_.Exception.Message)" "ERROR"

        [PSCustomObject]@{
            ExitCode = -1
            Success  = $false
            LogFile  = $LogFile
            Lines    = @()
            Error    = $_.Exception.Message
        }
    }
}

# ---------------- SUMMARY PARSING ---------------------------

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

        return [long](
            $Matches[1] -replace ',', ''
        )
    }

    return $null
}

# ---------------- SIZE FORMATTING ---------------------------

function Format-Size {

    param([long]$Bytes)

    if ($Bytes -ge 1TB) {
        return "{0:N2} TB" -f ($Bytes / 1TB)
    }

    if ($Bytes -ge 1GB) {
        return "{0:N2} GB" -f ($Bytes / 1GB)
    }

    if ($Bytes -ge 1MB) {
        return "{0:N2} MB" -f ($Bytes / 1MB)
    }

    if ($Bytes -ge 1KB) {
        return "{0:N2} KB" -f ($Bytes / 1KB)
    }

    return "$Bytes Bytes"
}

# ---------------- FOLDER STATISTICS ------------------------

function Get-RoboSummary {

    param([string]$Path)

    Write-Log "Calculating folder statistics: $Path"

    $Result = Invoke-RoboCommand `
        -Source $Path `
        -LogType "Statistics" `
        -Options @(
            "/L"
            "/B"
            "/E"
            "/BYTES"
            "/R:0"
            "/W:0"
            "/NFL"
            "/NDL"
            "/NJH"
            "/NP"
            "/XJ"
        )

    $Files = Get-RoboSummaryValue $Result.Lines "Files"
    $Dirs  = Get-RoboSummaryValue $Result.Lines "Dirs"
    $Bytes = Get-RoboSummaryValue $Result.Lines "Bytes"

    $Failed = $null

    $FileLine = $Result.Lines |
        Where-Object {
            $_ -match '^\s*Files\s*:'
        } |
        Select-Object -First 1

    if ($FileLine -match '^\s*Files\s*:\s*[\d,]+\s+[\d,]+\s+[\d,]+\s+[\d,]+\s+([\d,]+)') {

        $Failed = [long](
            $Matches[1] -replace ',', ''
        )
    }

    $Errors = [System.Collections.Generic.List[string]]::new()

    if ($Result.Error) {
        $Errors.Add($Result.Error)
    }

    if ($null -eq $Files) {
        $Errors.Add("Unable to parse file count.")
    }

    if ($null -eq $Dirs) {
        $Errors.Add("Unable to parse directory count.")
    }

    if ($null -eq $Bytes) {
        $Errors.Add("Unable to parse total bytes.")
    }

    [PSCustomObject]@{
        Files      = $Files
        Dirs       = $Dirs
        Bytes      = $Bytes
        Failed     = $Failed
        ExitCode   = $Result.ExitCode
        Success    = ($Result.Success -and $Errors.Count -eq 0)
        Errors     = @($Errors)
        LogFile    = $Result.LogFile
        RawOutput  = if ($Errors.Count -gt 0) {
            $Result.Lines
        } else {
            @()
        }
    }
}

# ---------------- SUBFOLDER DISCOVERY ----------------------

function Get-RoboChildDirectories {

    param([string]$Path)

    Write-Log "Discovering immediate subfolders: $Path"

    # IMPORTANT:
    # LEV:2 = source root + immediate child directories.

    $Result = Invoke-RoboCommand `
        -Source $Path `
        -LogType "Discovery" `
        -Options @(
            "/L"
            "/B"
            "/E"
            "/LEV:2"
            "/FP"
            "/R:0"
            "/W:0"
            "/NP"
            "/XJ"
            "/NJH"
            "/NJS"
        )

    $Directories = [System.Collections.Generic.List[string]]::new()

    foreach ($Line in $Result.Lines) {

        # English Robocopy output:
        # New Dir          6    E:\Shares\Data\

        if ($Line -match '^\s*New Dir\s+\d+\s+(.+?)\s*$') {

            $ChildPath = $Matches[1].Trim().TrimEnd('\')

            # Exclude the source directory itself.

            if ($ChildPath -ine $Path.TrimEnd('\')) {

                $Directories.Add($ChildPath)
            }
        }
    }

    $UniqueDirectories = @(
        $Directories | Sort-Object -Unique
    )

    $Errors = [System.Collections.Generic.List[string]]::new()

    if ($Result.Error) {

        $Errors.Add($Result.Error)
    }

    if ($UniqueDirectories.Count -eq 0 -and
        $Result.Success) {

        Write-Log "No immediate subfolders detected: $Path" "INFO"
    }

    if ($UniqueDirectories.Count -gt 0) {

        Write-Log "Discovered $($UniqueDirectories.Count) subfolders in $Path"
    }

    [PSCustomObject]@{
        Directories = $UniqueDirectories
        ExitCode    = $Result.ExitCode
        Success     = $Result.Success
        Errors      = @($Errors)
        LogFile     = $Result.LogFile
        RawOutput   = if (!$UniqueDirectories.Count) {
            $Result.Lines
        } else {
            @()
        }
    }
}

# ---------------- RECURSIVE SCANNING ------------------------

function New-FolderNode {

    param(
        [string]$Path,
        [int]$Depth
    )

    Write-Log "Scanning [$Depth/$MaxDepth]: $Path"

    $Stats = Get-RoboSummary -Path $Path

    $Children = [System.Collections.Generic.List[object]]::new()

    $Errors = [System.Collections.Generic.List[string]]::new()

    foreach ($ErrorMessage in $Stats.Errors) {
        $Errors.Add($ErrorMessage)
    }

    $Discovery = $null

    if ($Depth -lt $MaxDepth) {

        $Discovery = Get-RoboChildDirectories -Path $Path

        foreach ($ErrorMessage in $Discovery.Errors) {
            $Errors.Add("Discovery: $ErrorMessage")
        }

        # If Robocopy reports child directories in its statistics
        # but discovery finds none, record a diagnostic warning.

        if ($Stats.Dirs -gt 1 -and
            $Discovery.Directories.Count -eq 0 -and
            $Discovery.Success) {

            $Errors.Add(
                "Robocopy reports $($Stats.Dirs) directories but no immediate subfolders were parsed. Check discovery log."
            )
        }

        foreach ($ChildPath in $Discovery.Directories) {

            $ChildNode = New-FolderNode `
                -Path $ChildPath `
                -Depth ($Depth + 1)

            $Children.Add($ChildNode)
        }
    }

    # Determine scan status.

    $ChildWarnings = @(
        $Children | Where-Object {
            $_.ScanStatus -ne "Success"
        }
    )

    if (!$Stats.Success -or
        ($Discovery -and !$Discovery.Success)) {

        $Status = "Failed"
    }
    elseif ($Errors.Count -gt 0 -or
            ($null -ne $Stats.Failed -and $Stats.Failed -gt 0) -or
            $ChildWarnings.Count -gt 0) {

        $Status = "Warning"
    }
    else {

        $Status = "Success"
    }

    [PSCustomObject][ordered]@{

        Name       = Split-Path $Path -Leaf
        FullPath   = $Path
        Depth      = $Depth

        SizeBytes  = $Stats.Bytes

        Size       = if ($null -ne $Stats.Bytes) {
            Format-Size $Stats.Bytes
        } else {
            $null
        }

        FileCount  = $Stats.Files
        DirCount   = $Stats.Dirs

        FailedFiles = $Stats.Failed

        ExitCode   = $Stats.ExitCode

        DiscoveryExitCode = if ($Discovery) {
            $Discovery.ExitCode
        } else {
            $null
        }

        ScanStatus = $Status

        Errors     = @($Errors)

        StatisticsLog = $Stats.LogFile

        DiscoveryLog = if ($Discovery) {
            $Discovery.LogFile
        } else {
            $null
        }

        RawOutput = $Stats.RawOutput

        DiscoveryRawOutput = if ($Discovery) {
            $Discovery.RawOutput
        } else {
            @()
        }

        Children = $Children
    }
}

# ---------------- MAIN EXECUTION ---------------------------

try {

    Write-Log "=========================================="
    Write-Log "ROBOCOPY FOLDER SCAN STARTED"
    Write-Log "Root: $Root"
    Write-Log "Maximum depth: $MaxDepth"
    Write-Log "=========================================="

    if (!(Test-Path -LiteralPath $Root -PathType Container)) {

        throw "Root folder does not exist or is inaccessible: $Root"
    }

    if (!(Test-Path -LiteralPath $Robocopy -PathType Leaf)) {

        throw "Robocopy executable not found: $Robocopy"
    }

    $Root = (Resolve-Path -LiteralPath $Root -ErrorAction Stop).Path

    # Start recursive scan.

    $Tree = New-FolderNode `
        -Path $Root `
        -Depth 0

    # Build final report.

    $Report = [PSCustomObject][ordered]@{

        GeneratedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")

        Root        = $Root

        MaxDepth    = $MaxDepth

        ScanStatus  = $Tree.ScanStatus

        Tree        = $Tree

        Log         = @($script:LogEntries)
    }

    # Export JSON.

    $Json = $Report | ConvertTo-Json -Depth 100

    Set-Content `
        -LiteralPath $JsonOutput `
        -Value $Json `
        -Encoding UTF8 `
        -ErrorAction Stop

    Write-Log "=========================================="
    Write-Log "SCAN COMPLETED"
    Write-Log "JSON: $JsonOutput"
    Write-Log "MASTER LOG: $MasterLog"
    Write-Log "ROBOCOPY LOGS: $RoboLogDir"
    Write-Log "Overall status: $($Tree.ScanStatus)"
    Write-Log "=========================================="

}
catch {

    Write-Log "FATAL ERROR: $($_.Exception.Message)" "ERROR"

    throw
}
