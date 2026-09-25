<#
.SYNOPSIS
    Replaces the taskbar / Alt-Tab icon of the MSIX build of Claude Desktop with your
    own artwork.

.DESCRIPTION
    Windows takes the taskbar and Alt-Tab icon of a packaged app from the *unplated*
    Square44x44Logo assets inside the package. This script renders one source image
    (PNG or ICO) into every unplated asset the installed package ships, at exactly the
    size each file name asks for.

    Two situations, both handled automatically:

    - Claude Desktop 2.9939.2.0 and newer ship a full set of unplated assets
      (targetsize-16 ... targetsize-256, plus lightunplated variants for light taskbars).
      The icon is already sharp; use this script only if you prefer different artwork,
      for example the transparent star glyph that older versions used.

    - Older versions shipped a single 24x24 unplated asset, which Windows had to upscale
      on a 150% / 200% display, so the taskbar icon looked blurry. There the script
      writes a 256x256 image into that one file, which fixes the blur.

    File names are never changed, so resources.pri does not have to be rebuilt, the
    package does not have to be repacked or re-signed, and the package identity stays
    the same - your Claude login and application data are preserved.

    The script is idempotent: files that already match are skipped, and explorer.exe is
    restarted only if something actually changed.

    Plated assets (the Start menu tile) are left untouched.

.PARAMETER Restore
    Puts the original icons of the installed version back from its backup.

.PARAMETER SourceImage
    Artwork to use. A .png (any size, square, transparent background recommended) or an
    .ico, whose largest frame is used. Defaults to assets\taskbar-icon.png next to this
    script.

.PARAMETER BackupPath
    Root folder for the untouched originals, one subfolder per Claude version.
    Defaults to 'backup' next to this script.

.PARAMETER Unattended
    No console output (used by the scheduled task). Combine with -LogPath.

.PARAMETER LogPath
    Optional log file.

.EXAMPLE
    PS> .\Fix-ClaudeTaskbarIcon.ps1

.EXAMPLE
    PS> .\Fix-ClaudeTaskbarIcon.ps1 -SourceImage .\my-icon.ico

.EXAMPLE
    PS> .\Fix-ClaudeTaskbarIcon.ps1 -Restore

.NOTES
    Must be run from an elevated (Administrator) PowerShell session.
    A Claude Desktop update rewrites the package directory and reverts the icons;
    run this script again afterwards, or let Install-AutoReapply.ps1 do it for you.
#>
[CmdletBinding()]
param(
    [switch]$Restore,
    [string]$SourceImage,
    [string]$BackupPath,
    [switch]$Unattended,
    [string]$LogPath
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

# Unplated assets = taskbar, Alt-Tab, jump lists. "lightunplated" is used on light taskbars.
$UnplatedPattern = 'Square44x44Logo.targetsize-*_altform-*unplated.png'
# Packages older than 2.9939.2.0 ship only this one, at 24x24.
$LegacyUnplated  = 'Square44x44Logo.targetsize-24_altform-unplated.png'

function Log([string]$Message, [string]$Color = 'Gray') {
    if (-not $Unattended) { Write-Host $Message -ForegroundColor $Color }
    if ($LogPath) {
        Add-Content -Path $LogPath -Encoding UTF8 -Value ('{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $Message)
    }
}

function Assert-Elevated {
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This script must be run from an elevated PowerShell session (Run as Administrator).'
    }
}

function Get-ClaudePackage {
    $pkg = Get-AppxPackage -Name 'Claude' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $pkg) {
        throw 'No MSIX package named "Claude" is registered for this user. This script only applies to the MSIX/Store build of Claude Desktop.'
    }
    $assets = Join-Path $pkg.InstallLocation 'assets'
    if (-not (Test-Path $assets)) { throw "Package found at $($pkg.InstallLocation) but it has no 'assets' folder." }
    [pscustomobject]@{ Version = $pkg.Version; Assets = $assets }
}

function Get-SourceBitmap([string]$Path) {
    $full = (Resolve-Path $Path).Path
    if ([System.IO.Path]::GetExtension($full).ToLowerInvariant() -ne '.ico') {
        return New-Object System.Drawing.Bitmap $full
    }
    # Pick the largest frame out of the .ico.
    $bytes = [System.IO.File]::ReadAllBytes($full)
    $count = [BitConverter]::ToUInt16($bytes, 4)
    $best = $null; $bestEdge = -1
    for ($i = 0; $i -lt $count; $i++) {
        $entry = 6 + $i * 16
        $w = $bytes[$entry];     if ($w -eq 0) { $w = 256 }   # 0 means 256 in the ICO header
        $h = $bytes[$entry + 1]; if ($h -eq 0) { $h = 256 }
        $edge = [Math]::Min($w, $h)
        if ($edge -le $bestEdge) { continue }
        $bestEdge = $edge
        $best = @{ Length = [BitConverter]::ToUInt32($bytes, $entry + 8)
                   Offset = [BitConverter]::ToUInt32($bytes, $entry + 12)
                   Width  = $w; Height = $h }
    }
    if (-not $best) { throw "No icon directory entries found in $full" }

    $frame = New-Object byte[] $best.Length
    [Array]::Copy($bytes, $best.Offset, $frame, 0, $best.Length)
    if ($frame[0] -eq 0x89 -and $frame[1] -eq 0x50) {
        # PNG-compressed frame. GDI+ keeps reading from the backing stream, so clone
        # into a standalone bitmap before the stream dies.
        $ms = New-Object System.IO.MemoryStream (,$frame)
        try {
            $decoded = New-Object System.Drawing.Bitmap $ms
            try   { return $decoded.Clone([System.Drawing.Rectangle]::FromLTRB(0, 0, $decoded.Width, $decoded.Height),
                                          [System.Drawing.Imaging.PixelFormat]::Format32bppArgb) }
            finally { $decoded.Dispose() }
        } finally { $ms.Dispose() }
    }
    $icon = New-Object System.Drawing.Icon ($full, $best.Width, $best.Height)
    try { return $icon.ToBitmap() } finally { $icon.Dispose() }
}

function Get-SquarePngBytes([System.Drawing.Bitmap]$Image, [int]$Edge) {
    $bmp = New-Object System.Drawing.Bitmap $Edge, $Edge, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode  = 'HighQualityBicubic'
    $g.PixelOffsetMode    = 'HighQuality'
    $g.SmoothingMode      = 'HighQuality'
    $g.CompositingQuality = 'HighQuality'
    $g.Clear([System.Drawing.Color]::Transparent)
    $g.DrawImage($Image, (New-Object System.Drawing.Rectangle 0, 0, $Edge, $Edge))
    $g.Dispose()
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    $ms.ToArray()
}

function Get-Sha256([byte[]]$Bytes) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { [BitConverter]::ToString($sha.ComputeHash($Bytes)) } finally { $sha.Dispose() }
}

function Unlock-File([string]$Path) {
    # WindowsApps content is owned by TrustedInstaller; take ownership and grant Administrators full control.
    $admins = (New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-32-544').
              Translate([System.Security.Principal.NTAccount]).Value
    & takeown.exe /F "$Path"                        | Out-Null
    & icacls.exe  "$Path" /grant "${admins}:(F)" /C | Out-Null
}

function Write-Asset([string]$Target, [byte[]]$Content, [string]$VersionBackup) {
    $backupFile = Join-Path $VersionBackup (Split-Path -Leaf $Target)
    if (-not (Test-Path $backupFile)) { Copy-Item -Path $Target -Destination $backupFile -Force }
    Unlock-File -Path $Target
    # Write raw bytes rather than Copy-Item: some of these files are hard links to each
    # other inside the package, and this keeps the behaviour predictable.
    [System.IO.File]::WriteAllBytes($Target, $Content)
}

function Reset-ShellIconCache {
    Log 'Clearing the shell icon cache and restarting explorer.exe ...' 'Cyan'
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 800
    $cache = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer'
    foreach ($pattern in 'iconcache*.db', 'thumbcache*.db') {
        Get-ChildItem -Path $cache -Filter $pattern -Force -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
    if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
}

# ------------------------------------------------------------------------------

Assert-Elevated

if (-not $SourceImage) { $SourceImage = Join-Path $PSScriptRoot 'assets\taskbar-icon.png' }
if (-not $BackupPath)  { $BackupPath  = Join-Path $PSScriptRoot 'backup' }

$pkg           = Get-ClaudePackage
$versionBackup = Join-Path $BackupPath $pkg.Version
Log "Claude Desktop $($pkg.Version)" 'Cyan'
Log "Assets folder: $($pkg.Assets)"

$changed = 0

if ($Restore) {
    if (-not (Test-Path $versionBackup)) {
        throw "No backup for version $($pkg.Version) in $BackupPath - the fix was never applied to this version from here."
    }
    foreach ($file in Get-ChildItem $versionBackup -Filter *.png) {
        $target = Join-Path $pkg.Assets $file.Name
        if (-not (Test-Path $target)) { Log "  no longer in the package, skipped: $($file.Name)" 'Yellow'; continue }
        $content = [System.IO.File]::ReadAllBytes($file.FullName)
        if ((Get-Sha256 $content) -eq (Get-Sha256 ([System.IO.File]::ReadAllBytes($target)))) {
            Log ("  {0,-56} already original" -f $file.Name); continue
        }
        Unlock-File -Path $target
        [System.IO.File]::WriteAllBytes($target, $content)
        Log ("  {0,-56} restored" -f $file.Name) 'Green'
        $changed++
    }
} else {
    if (-not (Test-Path $SourceImage)) { throw "Source image not found: $SourceImage" }
    Log "Source image: $SourceImage"

    # Every unplated asset the installed package ships, at the size its name asks for.
    $targets = @(Get-ChildItem $pkg.Assets -Filter $UnplatedPattern -ErrorAction SilentlyContinue |
                 ForEach-Object {
                     if ($_.Name -match 'targetsize-(\d+)_altform') {
                         [pscustomobject]@{ Path = $_.FullName; Name = $_.Name; Edge = [int]$Matches[1] }
                     }
                 })
    if ($targets.Count -eq 0) {
        # Pre-2.9939 layout: a single 24x24 file. Write 256x256 into it so Windows has
        # something sharp to scale down from.
        $legacy = Join-Path $pkg.Assets $LegacyUnplated
        if (-not (Test-Path $legacy)) { throw "This package has no unplated Square44x44Logo assets - nothing this script knows how to fix." }
        $targets = @([pscustomobject]@{ Path = $legacy; Name = $LegacyUnplated; Edge = 256 })
        Log 'Old package layout: writing a single 256x256 unplated asset.' 'Yellow'
    }

    New-Item -ItemType Directory -Force -Path $versionBackup | Out-Null
    $source = Get-SourceBitmap $SourceImage
    try {
        foreach ($t in $targets) {
            $content = Get-SquarePngBytes $source $t.Edge
            if ((Get-Sha256 $content) -eq (Get-Sha256 ([System.IO.File]::ReadAllBytes($t.Path)))) {
                Log ("  {0,-56} already up to date" -f $t.Name); continue
            }
            Write-Asset -Target $t.Path -Content $content -VersionBackup $versionBackup
            Log ("  {0,-56} {1}x{1}" -f $t.Name, $t.Edge) 'Green'
            $changed++
        }
    } finally { $source.Dispose() }

    if ($changed -gt 0) { Log "Originals backed up to: $versionBackup" }
}

if ($changed -eq 0) { Log 'Nothing to change.' 'Green'; return }

Reset-ShellIconCache
Log 'Done.' 'Green'
Log 'If the taskbar still shows the old icon: unpin Claude, then pin it again, or sign out and back in.' 'Yellow'
