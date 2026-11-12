
# ============================================================
# ROBOCOPY FOLDER SIZE SCANNER
#
# - Backup mode (/B)
# - List only (/L) - no files copied
# - Recursive folder scanning
# - Flat CSV output (one row per folder)
# - Individual Robocopy logs
# - Master execution log
# - Configurable folder depth
# - Quiet console progress reporting
# - Total scan duration reporting
#
# Compatible with Windows PowerShell 5.1
# ============================================================


# ---------------- CONFIGURATION -----------------------------

$Root       = "E:\Shares\Data"
$MaxDepth   = 3

$OutputDir  = "C:\Temp\RoboSizeReport"
$CsvOutput  = Join-Path $OutputDir "FolderReport.csv"
$MasterLog  = Join-Path $OutputDir "Execution.log"
$RoboLogDir = Join-Path $OutputDir "RobocopyLogs"

$Robocopy = "$env:windir\System32\robocopy.exe"

# Console progress interval.
# Set to 1 to show every folder, or increase for less output.
$ProgressInterval = 25


# ---------------- INITIALISATION ----------------------------

New-Item -ItemType Directory -Path $OutputDir -Force |
    Out-Null

New-Item -ItemType Directory -Path $RoboLogDir -Force |
    Out-Null

# Reset previous report and master log.
Remove-Item -LiteralPath $CsvOutput -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $MasterLog -Force -ErrorAction SilentlyContinue

$script:ScanCounter = 0
$script:ProcessedFolders = 0
$script:Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

# CSV columns.
$script:CsvColumns = @(
    "GeneratedAt"
    "Name"
    "FullPath"
    "ParentPath"
    "Depth"
    "SizeBytes"
    "Size"
    "FileCount"
    "DirCount"
    "FailedFiles"
    "ExitCode"
    "DiscoveryExitCode"
    "ScanStatus"
    "Errors"
    "StatisticsLog"
    "DiscoveryLog"
)

# Create CSV header.
$script:CsvColumns -join "," |
    Set-Content -LiteralPath $CsvOutput -Encoding UTF8


# ---------------- HELPER: DURATION --------------------------

function Format-Duration {

    param(
        [TimeSpan]$Duration
    )

    return $Duration.ToString("d\.hh\:mm\:ss")
}


# ---------------- MASTER LOGGING ----------------------------

function Write-Log {

    param(
        [string]$Message,
        [string]$Level = "INFO"
    )

    $Entry = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] $Message"

    Add-Content -LiteralPath $MasterLog -Value $Entry
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
            } else {
                $null
            }
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


# ---------------- FOLDER STATISTICS -------------------------

function Get-RoboSummary {

    param([string]$Path)

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
        Files     = $Files
        Dirs      = $Dirs
        Bytes     = $Bytes
        Failed    = $Failed
        ExitCode  = $Result.ExitCode
        Success   = ($Result.Success -and $Errors.Count -eq 0)
        Errors    = @($Errors)
        LogFile   = $Result.LogFile
    }
}


# ---------------- SUBFOLDER DISCOVERY -----------------------

function Get-RoboChildDirectories {

    param([string]$Path)

    # LEV:2 = source root + immediate child directories.
    # This remains unchanged when increasing MaxDepth.

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

        if ($Line -match '^\s*New Dir\s+\d+\s+(.+?)\s*$') {

            $ChildPath = $Matches[1].Trim().TrimEnd('\')

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

    [PSCustomObject]@{
        Directories = $UniqueDirectories
        ExitCode    = $Result.ExitCode
        Success     = $Result.Success
        Errors      = @($Errors)
        LogFile     = $Result.LogFile
    }
}


# ---------------- CSV EXPORT --------------------------------

function Export-FolderRecord {

    param(
        [PSCustomObject]$Record
    )

    $Record |
        Select-Object $script:CsvColumns |
        Export-Csv `
            -LiteralPath $CsvOutput `
            -NoTypeInformation `
            -Append `
            -Encoding UTF8
}


# ---------------- RECURSIVE SCANNING ------------------------

function New-FolderNode {

    param(
        [string]$Path,
        [int]$Depth
    )

    $Stats = Get-RoboSummary -Path $Path

    $Errors = [System.Collections.Generic.List[string]]::new()

    foreach ($ErrorMessage in $Stats.Errors) {
        $Errors.Add($ErrorMessage)
    }

    $Discovery = $null
    $ChildWarnings = $false

    if ($Depth -lt $MaxDepth) {

        $Discovery = Get-RoboChildDirectories -Path $Path

        foreach ($ErrorMessage in $Discovery.Errors) {
            $Errors.Add("Discovery: $ErrorMessage")
        }

        if ($Stats.Dirs -gt 1 -and
            $Discovery.Directories.Count -eq 0 -and
            $Discovery.Success) {

            $Errors.Add(
                "Robocopy reports $($Stats.Dirs) directories but no immediate subfolders were parsed. Check discovery log."
            )
        }

        foreach ($ChildPath in $Discovery.Directories) {

            # Capture the child's status so warnings and failures
            # can be reflected in the parent folder's status.

            $ChildStatus = New-FolderNode `
                -Path $ChildPath `
                -Depth ($Depth + 1)

            if ($ChildStatus -ne "Success") {
                $ChildWarnings = $true
            }
        }
    }

    # Determine folder status.

    if (!$Stats.Success -or
        ($Discovery -and !$Discovery.Success)) {

        $Status = "Failed"
    }
    elseif ($Errors.Count -gt 0 -or
            ($null -ne $Stats.Failed -and $Stats.Failed -gt 0) -or
            $ChildWarnings) {

        $Status = "Warning"
    }
    else {

        $Status = "Success"
    }

    # Build flat CSV record.

    $Record = [PSCustomObject][ordered]@{

        GeneratedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")

        Name        = Split-Path $Path -Leaf
        FullPath    = $Path
        ParentPath  = Split-Path $Path -Parent
        Depth       = $Depth

        SizeBytes   = $Stats.Bytes

        Size        = if ($null -ne $Stats.Bytes) {
            Format-Size $Stats.Bytes
        } else {
            $null
        }

        FileCount   = $Stats.Files
        DirCount    = $Stats.Dirs

        FailedFiles = $Stats.Failed

        ExitCode    = $Stats.ExitCode

        DiscoveryExitCode = if ($Discovery) {
            $Discovery.ExitCode
        } else {
            $null
        }

        ScanStatus  = $Status

        Errors      = (@($Errors) -join " | ")

        StatisticsLog = $Stats.LogFile

        DiscoveryLog = if ($Discovery) {
            $Discovery.LogFile
        } else {
            $null
        }
    }

    # Export immediately rather than building a large object tree.

    Export-FolderRecord -Record $Record

    # Update progress counter.

    $script:ProcessedFolders++

    if (($script:ProcessedFolders % $ProgressInterval) -eq 0) {

        $Elapsed = Format-Duration $script:Stopwatch.Elapsed

        Write-Host (
            "[{0}] Processed {1:N0} folders | Latest: {2}" -f
            $Elapsed,
            $script:ProcessedFolders,
            $Path
        ) -ForegroundColor Cyan
    }

    # Return only the status string to the parent call.

    return $Status
}


# ---------------- MAIN EXECUTION ----------------------------

try {

    Write-Log "=========================================="
    Write-Log "ROBOCOPY FOLDER SCAN STARTED"
    Write-Log "Root: $Root"
    Write-Log "Maximum depth: $MaxDepth"
    Write-Log "=========================================="

    Write-Host ""
    Write-Host "Robocopy folder scan started" -ForegroundColor Green
    Write-Host "Root: $Root"
    Write-Host "Maximum depth: $MaxDepth"
    Write-Host "Progress displayed every $ProgressInterval folders"
    Write-Host ""

    if (!(Test-Path -LiteralPath $Root -PathType Container)) {
        throw "Root folder does not exist or is inaccessible: $Root"
    }

    if (!(Test-Path -LiteralPath $Robocopy -PathType Leaf)) {
        throw "Robocopy executable not found: $Robocopy"
    }

    if ($MaxDepth -lt 0) {
        throw "MaxDepth must be zero or greater."
    }

    if ($ProgressInterval -lt 1) {
        throw "ProgressInterval must be at least 1."
    }

    $Root = (Resolve-Path -LiteralPath $Root -ErrorAction Stop).Path

    # Start recursive scan.
    # Root is depth 0.

    $OverallStatus = New-FolderNode `
        -Path $Root `
        -Depth 0

    $script:Stopwatch.Stop()

    $Duration = Format-Duration $script:Stopwatch.Elapsed

    Write-Log "=========================================="
    Write-Log "SCAN COMPLETED"
    Write-Log "CSV: $CsvOutput"
    Write-Log "MASTER LOG: $MasterLog"
    Write-Log "ROBOCOPY LOGS: $RoboLogDir"
    Write-Log "Folders processed: $($script:ProcessedFolders)"
    Write-Log "Duration: $Duration"
    Write-Log "Overall status: $OverallStatus"
    Write-Log "=========================================="

    # Final console summary.

    Write-Host ""
    Write-Host "==========================================" -ForegroundColor Green
    Write-Host "SCAN COMPLETED" -ForegroundColor Green
    Write-Host "=========================================="
    Write-Host "Folders processed : $($script:ProcessedFolders)"
    Write-Host "Maximum depth     : $MaxDepth"
    Write-Host "Duration          : $Duration"
    Write-Host "Overall status    : $OverallStatus"
    Write-Host ""
    Write-Host "CSV report        : $CsvOutput"
    Write-Host "Master log        : $MasterLog"
    Write-Host "Robocopy logs     : $RoboLogDir"
    Write-Host "==========================================" -ForegroundColor Green

}
catch {

    $script:Stopwatch.Stop()

    $Duration = Format-Duration $script:Stopwatch.Elapsed

    Write-Log "FATAL ERROR: $($_.Exception.Message)" "ERROR"
    Write-Log "Elapsed before failure: $Duration"

    Write-Host ""
    Write-Host "SCAN FAILED: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Elapsed time: $Duration" -ForegroundColor Yellow
    Write-Host "Check master log: $MasterLog" -ForegroundColor Yellow

    throw
}
