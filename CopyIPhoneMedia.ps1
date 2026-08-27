<#
.SYNOPSIS
    Copies iPhone media files (.MOV, .JPG, .HEIC by default) to a folder on the PC.

.DESCRIPTION
    An iPhone connected by cable appears as an MTP device: it has no drive letter,
    so cp / robocopy / Get-ChildItem cannot read it. This script talks to the same
    Windows shell interface Explorer uses, so it can walk the device directly.

    The source may be a device path ("This PC\Apple iPhone\Internal Storage\202406_a")
    or an ordinary folder ("E:\DCIM") - both work.

.EXAMPLE
    .\Copy-IPhoneMedia.ps1 "This PC\Apple iPhone\Internal Storage\202406_a" "D:\Photos"

.EXAMPLE
    .\Copy-IPhoneMedia.ps1 "This PC\Apple iPhone\Internal Storage" "D:\Photos" -Folders "2024*"

.EXAMPLE
    .\Copy-IPhoneMedia.ps1 "This PC\Apple iPhone\Internal Storage" "D:\Photos" -DryRun
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string] $Source,

    [Parameter(Mandatory = $true, Position = 1)]
    [string] $Destination,

    # File types to copy.
    [string[]] $Extensions = @('.MOV', '.JPG', '.HEIC'),

    # Which first-level sub-folders to enter, e.g. "2024*". Default: all of them.
    [string] $Folders = '*',

    # Put every file straight into the destination instead of recreating 202406_a\...
    [switch] $Flat,

    # Re-copy files that exist with a different size (default: keep both as name_1.ext).
    [switch] $Overwrite,

    # List what would be copied without copying anything.
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'

$NO_PROGRESS_DIALOG = 4
$YES_TO_ALL         = 16
$THIS_PC            = 17
$COPY_FLAGS         = $NO_PROGRESS_DIALOG -bor $YES_TO_ALL
$COPY_TIMEOUT_SEC   = 600   # a single 4K video can take a while over USB

$Shell  = New-Object -ComObject Shell.Application
$Wanted = $Extensions | ForEach-Object {
    if ($_.StartsWith('.')) { $_.ToLower() } else { '.' + $_.ToLower() }
}

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

function Resolve-DeviceFolder {
    param([string] $Path)

    $parts = @($Path -split '[\\/]+' | Where-Object { $_ -ne '' })
    if ($parts.Count -gt 0 -and @('this pc', 'computer', 'my computer') -contains $parts[0].ToLower()) {
        if ($parts.Count -gt 1) { $parts = $parts[1..($parts.Count - 1)] } else { $parts = @() }
    }

    $folder = $Shell.NameSpace($THIS_PC)
    $walked = 'This PC'

    foreach ($part in $parts) {
        $next = $null
        foreach ($item in $folder.Items()) {
            if ($item.IsFolder -and $item.Name -eq $part) { $next = $item.GetFolder; break }
        }
        if ($null -eq $next) {
            $available = ($folder.Items() | Where-Object { $_.IsFolder } | ForEach-Object { $_.Name }) -join ', '
            throw "'$part' not found under $walked.`nAvailable: $available`nIs the phone unlocked and 'Trust This Computer' accepted?"
        }
        $folder = $next
        $walked = "$walked\$part"
    }
    return $folder
}

function Get-MediaItems {
    param($Folder, [string] $Relative = '', [bool] $Top = $true)

    $found = @()
    foreach ($item in $Folder.Items()) {
        if ($item.IsFolder) {
            if ($Top -and $item.Name -notlike $Folders) { continue }
            if ($Relative) { $childRelative = Join-Path $Relative $item.Name }
            else           { $childRelative = $item.Name }
            $found += @(Get-MediaItems -Folder $item.GetFolder -Relative $childRelative -Top $false)
        }
        else {
            $extension = [System.IO.Path]::GetExtension($item.Name).ToLower()
            if ($Wanted -contains $extension) {
                $found += [pscustomobject]@{ Relative = $Relative; Item = $item; Folder = $Folder }
            }
        }
    }
    return $found
}

function Get-ItemSize {
    param($Item)
    try { return [int64] $Item.Size } catch { return 0 }   # MTP always reports 0
}

function Get-SizeLabel {
    # A device reports no byte count, but the shell still shows a rounded size
    # ("989 KB") in its details column, which is good enough to print.
    param($Folder, $Item, [int64] $ExactSize)

    if ($ExactSize -gt 0) { return Format-Size $ExactSize }

    if ($null -eq $script:SizeColumn) {
        $script:SizeColumn = -1
        foreach ($column in 0..40) {
            if ($Folder.GetDetailsOf($null, $column) -eq 'Size') { $script:SizeColumn = $column; break }
        }
    }
    if ($script:SizeColumn -ge 0) { return $Folder.GetDetailsOf($Item, $script:SizeColumn) }
    return ''
}

function Get-FreeName {
    param([string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $Path }

    $directory = Split-Path -Path $Path -Parent
    $base      = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    $extension = [System.IO.Path]::GetExtension($Path)

    $counter = 1
    while ($true) {
        $candidate = Join-Path $directory "${base}_$counter$extension"
        if (-not (Test-Path -LiteralPath $candidate)) { return $candidate }
        $counter++
    }
}

function Find-ExistingCopy {
    # Is this file already here, either under its own name or as a name_1 /
    # name_2 sibling from an earlier run? Needs a real byte count to tell.
    param([string] $Path, [int64] $Size)

    if ($Size -le 0) { return $null }

    $directory = Split-Path -Path $Path -Parent
    if (-not (Test-Path -LiteralPath $directory)) { return $null }

    $base    = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    $pattern = '^' + [regex]::Escape($base) + '(_\d+)?$'

    $siblings = Get-ChildItem -LiteralPath $directory -File -Filter "$base*" -ErrorAction SilentlyContinue
    foreach ($candidate in $siblings) {
        if ($candidate.BaseName -match $pattern -and $candidate.Length -eq $Size) {
            return $candidate.FullName
        }
    }
    return $null
}

function Wait-ForFile {
    # CopyHere is asynchronous - wait until the file exists and has stopped growing.
    param([string] $Path, [int] $TimeoutSeconds = 600)

    $deadline    = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastSize    = -1
    $stableSince = $null

    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $Path) {
            $size = (Get-Item -LiteralPath $Path).Length
            if ($size -eq $lastSize -and $size -gt 0) {
                if ($null -eq $stableSince) { $stableSince = Get-Date }
                elseif (((Get-Date) - $stableSince).TotalSeconds -gt 1) { return $true }
            }
            else { $stableSince = $null }
            $lastSize = $size
        }
        Start-Sleep -Milliseconds 300
    }
    return $false
}

function Format-Size {
    param([double] $Bytes)
    foreach ($unit in 'B', 'KB', 'MB', 'GB') {
        if ($Bytes -lt 1024) { return ('{0:N1} {1}' -f $Bytes, $unit) }
        $Bytes = $Bytes / 1024
    }
    return ('{0:N1} TB' -f $Bytes)
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

$Destination = (New-Item -ItemType Directory -Force -Path $Destination).FullName

if (Test-Path -LiteralPath $Source -PathType Container) {
    $sourceFolder = $Shell.NameSpace((Resolve-Path -LiteralPath $Source).Path)
}
else {
    Write-Host "Opening device: $Source"
    $sourceFolder = Resolve-DeviceFolder -Path $Source
}

Write-Host 'Reading file list (this can take a moment on a device)...'
$files = @(Get-MediaItems -Folder $sourceFolder)

if ($files.Count -eq 0) {
    Write-Host "No $($Extensions -join ', ') files found in $Source"
    return
}

Write-Host "Found $($files.Count) file(s)`n"

$copied      = 0
$copiedBytes = 0
$skipped     = 0
$failed      = 0
$index       = 0

foreach ($entry in $files) {
    $index++
    $item = $entry.Item
    $size = Get-ItemSize -Item $item

    if ($Flat -or -not $entry.Relative) { $targetDirectory = $Destination }
    else { $targetDirectory = Join-Path $Destination $entry.Relative }

    $landing = Join-Path $targetDirectory $item.Name
    $useTemp = $false

    $existing = Find-ExistingCopy -Path $landing -Size $size
    if ($existing) {
        Write-Host "[$index/$($files.Count)] skip (already there) $($item.Name)"
        $skipped++
        continue
    }

    if (Test-Path -LiteralPath $landing) {
        # A device gives no byte count, so there the name alone has to decide.
        if ($size -eq 0) {
            Write-Host "[$index/$($files.Count)] skip (already there) $($item.Name)"
            $skipped++
            continue
        }
        # Same name, different file: keep both unless -Overwrite was passed.
        if (-not $Overwrite) { $useTemp = $true }
    }

    $sizeLabel = Get-SizeLabel -Folder $entry.Folder -Item $item -ExactSize $size
    if ($sizeLabel) { $label = " ($sizeLabel)" } else { $label = '' }
    Write-Host "[$index/$($files.Count)] $($item.Name) -> $landing$label"

    if ($DryRun) { continue }

    New-Item -ItemType Directory -Force -Path $targetDirectory | Out-Null

    # The shell always copies under the original name, so when we need a different
    # one we copy into a staging folder first and rename on the way out.
    if ($useTemp) {
        $stagingDirectory = Join-Path $targetDirectory '.copy-staging'
        New-Item -ItemType Directory -Force -Path $stagingDirectory | Out-Null
        $arrival = Join-Path $stagingDirectory $item.Name
        $target  = $stagingDirectory
    }
    else {
        $arrival = $landing
        $target  = $targetDirectory
    }

    $targetNamespace = $Shell.NameSpace($target)
    if ($null -eq $targetNamespace) {
        Write-Host "    failed: cannot open destination $target"
        $failed++
        continue
    }

    $targetNamespace.CopyHere($item, $COPY_FLAGS)

    if (-not (Wait-ForFile -Path $arrival -TimeoutSeconds $COPY_TIMEOUT_SEC)) {
        Write-Host '    failed: file never arrived (timed out)'
        $failed++
        continue
    }

    if ($useTemp) {
        $finalPath = Get-FreeName -Path $landing
        Move-Item -LiteralPath $arrival -Destination $finalPath
        Remove-Item -LiteralPath $stagingDirectory -Recurse -Force
        Write-Host "    saved as $(Split-Path $finalPath -Leaf)"
    }
    else {
        $finalPath = $landing
    }

    $copied++
    $copiedBytes += (Get-Item -LiteralPath $finalPath).Length
}

Write-Host ''
if ($DryRun) {
    Write-Host "Dry run: $($files.Count - $skipped) file(s) would be copied, $skipped skipped"
}
else {
    Write-Host "Copied $copied file(s) ($(Format-Size $copiedBytes)), skipped $skipped, failed $failed"
}
