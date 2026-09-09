<#
.SYNOPSIS
    Replaces the low-resolution taskbar icon of the MSIX build of Claude Desktop
    with 256x256 assets.

.DESCRIPTION
    The MSIX package of Claude Desktop ships its unplated taskbar icon
    (Assets\Square44x44Logo.targetsize-24_altform-unplated.png) at 24x24 pixels only.
    On a display running at 150% / 200% scaling the shell needs a 36 / 48 pixel icon
    and has nothing better to work with, so it upscales the 24x24 bitmap and the
    taskbar icon looks blurry.

    This script takes ownership of the affected PNG files inside
    C:\Program Files\WindowsApps\Claude_<version>_x64__<hash>\assets and overwrites
    them with 256x256 versions.

    File names are kept identical, so resources.pri does not have to be rebuilt,
    the package does not have to be repacked or re-signed, and the package identity
    is untouched - your Claude login and application data are preserved.

.PARAMETER Restore
    Puts the original icons back from the backup created on the first run.

.PARAMETER AssetsPath
    Folder holding the replacement PNG files. Defaults to the 'assets' folder
    next to this script.

.PARAMETER BackupPath
    Folder used to store the untouched originals. Defaults to 'backup' next to
    this script.

.EXAMPLE
    PS> .\Fix-ClaudeTaskbarIcon.ps1

.EXAMPLE
    PS> .\Fix-ClaudeTaskbarIcon.ps1 -Restore

.NOTES
    Must be run from an elevated (Administrator) PowerShell session.
    A Claude Desktop update rewrites the package directory and reverts the icons;
    simply run this script again afterwards.
#>
[CmdletBinding()]
param(
    [switch]$Restore,
    [string]$AssetsPath,
    [string]$BackupPath
)

$ErrorActionPreference = 'Stop'

# --- The PNG files the shell reads for taskbar, Alt-Tab, Start menu and package logo ---
$IconFiles = @(
    'Square44x44Logo.targetsize-24_altform-unplated.png'  # taskbar + Alt-Tab
    'Square44x44Logo.png'                                 # Start menu tile
    'Square44x44Logo.scale-200.png'                       # Start menu tile @200%
    'icon.png'                                            # package logo
)

function Assert-Elevated {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]$identity
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This script must be run from an elevated PowerShell session (Run as Administrator).'
    }
}

function Get-ClaudeAssetsFolder {
    $pkg = Get-AppxPackage -Name 'Claude' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $pkg) {
        throw 'No MSIX package named "Claude" is registered for this user. This script only applies to the MSIX/Store build of Claude Desktop.'
    }
    $assets = Join-Path $pkg.InstallLocation 'assets'
    if (-not (Test-Path $assets)) {
        throw "Package found at $($pkg.InstallLocation) but it has no 'assets' folder."
    }
    [pscustomobject]@{ Version = $pkg.Version; Path = $assets }
}

function Unlock-File {
    param([string]$Path)
    # WindowsApps content is owned by TrustedInstaller; take ownership and grant Administrators full control.
    $admins = (New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-32-544').
              Translate([System.Security.Principal.NTAccount]).Value
    & takeown.exe /F "$Path"                       | Out-Null
    & icacls.exe  "$Path" /grant "${admins}:(F)" /C | Out-Null
}

function Reset-ShellIconCache {
    Write-Host 'Clearing the shell icon cache and restarting explorer.exe ...' -ForegroundColor Cyan
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 800
    $cache = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer'
    foreach ($pattern in 'iconcache*.db', 'thumbcache*.db') {
        Get-ChildItem -Path $cache -Filter $pattern -Force -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
    if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) {
        Start-Process explorer.exe
    }
}

# ------------------------------------------------------------------------------

Assert-Elevated

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $AssetsPath) { $AssetsPath = Join-Path $scriptRoot 'assets' }
if (-not $BackupPath) { $BackupPath = Join-Path $scriptRoot 'backup' }

$pkg = Get-ClaudeAssetsFolder
Write-Host "Claude Desktop $($pkg.Version)" -ForegroundColor Cyan
Write-Host "Assets folder: $($pkg.Path)`n"

$sourceDir = if ($Restore) { $BackupPath } else { $AssetsPath }
if (-not (Test-Path $sourceDir)) {
    throw "Source folder not found: $sourceDir" +
          $(if ($Restore) { ' - there is nothing to restore (the fix was never applied from this folder).' } else { '' })
}

if (-not $Restore) { New-Item -ItemType Directory -Force -Path $BackupPath | Out-Null }

$changed = 0
foreach ($name in $IconFiles) {
    $target = Join-Path $pkg.Path   $name
    $source = Join-Path $sourceDir  $name

    if (-not (Test-Path $target)) { Write-Warning "Not present in the package, skipped: $name"; continue }
    if (-not (Test-Path $source)) { Write-Warning "Not present in $sourceDir, skipped: $name";  continue }

    # Back up the pristine original once, before the first overwrite.
    if (-not $Restore) {
        $backupFile = Join-Path $BackupPath $name
        if (-not (Test-Path $backupFile)) { Copy-Item -Path $target -Destination $backupFile -Force }
    }

    Unlock-File -Path $target

    # Write raw bytes rather than Copy-Item: several of these files are hard links
    # to each other inside the package, and this keeps the behaviour predictable.
    [System.IO.File]::WriteAllBytes($target, [System.IO.File]::ReadAllBytes($source))

    $size = (Get-Item $target).Length
    Write-Host ("  {0,-52} {1,8:N0} bytes" -f $name, $size) -ForegroundColor Green
    $changed++
}

if ($changed -eq 0) { Write-Warning 'Nothing was changed.'; return }

if (-not $Restore) { Write-Host "`nOriginals backed up to: $BackupPath" }

Write-Host ''
Reset-ShellIconCache

Write-Host "`nDone." -ForegroundColor Green
Write-Host 'If the taskbar still shows the old icon: unpin Claude, then pin it again, or sign out and back in.' -ForegroundColor Yellow
