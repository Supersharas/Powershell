
# ============================================================
# Robocopy Folder Size Scanner
# Backup mode + JSON export + hierarchical folder structure
# ============================================================

$Root       = "D:\Data"
$MaxDepth   = 3
$JsonOutput = "C:\Temp\FolderReport.json"

$Robocopy = "$env:windir\System32\robocopy.exe"
$DummyDestination = Join-Path $env:TEMP "RoboSize_Dummy"

# ------------------------------------------------------------
# Extract first numeric value from a Robocopy summary line
# ------------------------------------------------------------

function Get-RoboValue {
    param(
        [string[]]$Lines,
        [string]$Label
    )

    $Line = $Lines |
        Where-Object { $_ -match "^\s*$Label\s*:" } |
        Select-Object -First 1

    if ($Line -match ':\s*([\d,]+)') {
        return [long]($Matches[1] -replace ',', '')
    }

    return 0
}

# ------------------------------------------------------------
# Get folder statistics using Robocopy
# ------------------------------------------------------------

function Get-RoboSummary {
    param([string]$Path)

    $Output = & $Robocopy $Path $DummyDestination `
        /L /B /E /BYTES /R:0 /W:0 `
        /NFL /NDL /NJH /NP /XJ 2>&1

    $ExitCode = $LASTEXITCODE
    $Lines = @($Output | ForEach-Object { $_.ToString() })

    $Files = Get-RoboValue $Lines "Files"
    $Dirs  = Get-RoboValue $Lines "Dirs"
    $Bytes = Get-RoboValue $Lines "Bytes"

    $Failed = 0
    $FileLine = $Lines |
        Where-Object { $_ -match '^\s*Files\s*:' } |
        Select-Object -First 1

    if ($FileLine -match '^\s*Files\s*:\s*[\d,]+\s+[\d,]+\s+[\d,]+\s+[\d,]+\s+([\d,]+)') {
        $Failed = [long]($Matches[1] -replace ',', '')
    }

    [PSCustomObject]@{
        Files    = $Files
        Dirs     = $Dirs
        Bytes    = $Bytes
        Failed   = $Failed
        ExitCode = $ExitCode
    }
}

# ------------------------------------------------------------
# Discover immediate subfolders using Robocopy backup mode
# ------------------------------------------------------------

function Get-RoboChildDirectories {
    param([string]$Path)

    $Output = & $Robocopy $Path $DummyDestination `
        /L /B /E /LEV:1 /R:0 /W:0 `
        /NFL /NJH /NJS /FP /NP /XJ 2>&1

    $ExitCode = $LASTEXITCODE

    foreach ($Line in $Output) {

        # English Robocopy output: New Dir <size> <full path>
        if ($Line.ToString() -match '^\s*New Dir\s+\d+\s+(.+?)\s*$') {

            $ChildPath = $Matches[1].Trim().TrimEnd('\')

            if ($ChildPath -and
                $ChildPath -ne $Path.TrimEnd('\')) {

                $ChildPath
            }
        }
    }
}

# ------------------------------------------------------------
# Format file size
# ------------------------------------------------------------

function Format-Size {
    param([long]$Bytes)

    if ($Bytes -ge 1TB) {
        return "{0:N2} TB" -f ($Bytes / 1TB)
    }
    elseif ($Bytes -ge 1GB) {
        return "{0:N2} GB" -f ($Bytes / 1GB)
    }
    elseif ($Bytes -ge 1MB) {
        return "{0:N2} MB" -f ($Bytes / 1MB)
    }
    elseif ($Bytes -ge 1KB) {
        return "{0:N2} KB" -f ($Bytes / 1KB)
    }

    return "$Bytes Bytes"
}

# ------------------------------------------------------------
# Build hierarchical folder tree
# ------------------------------------------------------------

function New-FolderNode {
    param(
        [string]$Path,
        [int]$Depth
    )

    Write-Host "Scanning: $Path" -ForegroundColor DarkGray

    $Stats = Get-RoboSummary -Path $Path

    $Children = [System.Collections.Generic.List[object]]::new()

    if ($Depth -lt $MaxDepth) {

        $ChildFolders = @(
            Get-RoboChildDirectories -Path $Path |
                Sort-Object -Unique
        )

        foreach ($Child in $ChildFolders) {

            $ChildNode = New-FolderNode `
                -Path $Child `
                -Depth ($Depth + 1)

            $Children.Add($ChildNode)
        }
    }

    [PSCustomObject][ordered]@{
        Name        = Split-Path $Path -Leaf
        FullPath    = $Path
        Depth       = $Depth
        SizeBytes   = $Stats.Bytes
        Size        = Format-Size $Stats.Bytes
        FileCount   = $Stats.Files
        DirCount    = $Stats.Dirs
        FailedFiles = $Stats.Failed
        ExitCode    = $Stats.ExitCode
        Children    = $Children
    }
}

# ------------------------------------------------------------
# Start scanning
# ------------------------------------------------------------

if (!(Test-Path -LiteralPath $Root -PathType Container)) {
    throw "Source folder does not exist: $Root"
}

$Root = (Resolve-Path -LiteralPath $Root).Path

$Tree = New-FolderNode -Path $Root -Depth 0

# ------------------------------------------------------------
# Export JSON
# ------------------------------------------------------------

$Report = [PSCustomObject][ordered]@{
    GeneratedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    Root        = $Root
    MaxDepth    = $MaxDepth
    Tree        = $Tree
}

$OutputDirectory = Split-Path $JsonOutput -Parent

if (!(Test-Path $OutputDirectory)) {
    New-Item -ItemType Directory -Path $OutputDirectory -Force |
        Out-Null
}

$Report |
    ConvertTo-Json -Depth 100 |
    Set-Content -LiteralPath $JsonOutput -Encoding UTF8

Write-Host ""
Write-Host "Scan completed!" -ForegroundColor Green
Write-Host "JSON report: $JsonOutput" -ForegroundColor Cyan
