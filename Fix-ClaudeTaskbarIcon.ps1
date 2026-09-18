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

    The script is idempotent: files that already match the replacement are skipped,
    and explorer.exe is restarted only if something actually changed.

.PARAMETER Restore
    Puts the original icons of the installed version back from its backup.

.PARAMETER AssetsPath
    Folder holding the replacement PNG files. Defaults to 'assets' next to this script.

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
    PS> .\Fix-ClaudeTaskbarIcon.ps1 -Restore

.NOTES
    Must be run from an elevated (Administrator) PowerShell session.
    A Claude Desktop update rewrites the package directory and reverts the icons;
    run this script again afterwards, or let Install-AutoReapply.ps1 do it for you.
#>
[CmdletBinding()]
param(
    [switch]$Restore,
    [string]$AssetsPath,
    [string]$BackupPath,
    [switch]$Unattended,
    [string]$LogPath
)

$ErrorActionPreference = 'Stop'

# --- The PNG files the shell reads for taskbar, Alt-Tab, Start menu and package logo ---
$IconFiles = @(
    'Square44x44Logo.targetsize-24_altform-unplated.png'  # taskbar + Alt-Tab
    'Square44x44Logo.png'                                 # Start menu tile
    'Square44x44Logo.scale-200.png'                       # Start menu tile @200%
    'icon.png'                                            # package logo
)

function Log([string]$Message, [string]$Color = 'Gray') {
    if (-not $Unattended) { Write-Host $Message -ForegroundColor $Color }
    if ($LogPath) {
        Add-Content -Path $LogPath -Encoding UTF8 -Value ('{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $Message)
    }
}

function Assert-Elevated {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]$identity
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
    if (-not (Test-Path $assets)) {
        throw "Package found at $($pkg.InstallLocation) but it has no 'assets' folder."
    }
    [pscustomobject]@{ Version = $pkg.Version; Assets = $assets }
}

function Test-SameContent([string]$A, [string]$B) {
    (Get-FileHash -Algorithm SHA256 $A).Hash -eq (Get-FileHash -Algorithm SHA256 $B).Hash
}

function Unlock-File([string]$Path) {
    # WindowsApps content is owned by TrustedInstaller; take ownership and grant Administrators full control.
    $admins = (New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-32-544').
              Translate([System.Security.Principal.NTAccount]).Value
    & takeown.exe /F "$Path"                       | Out-Null
    & icacls.exe  "$Path" /grant "${admins}:(F)" /C | Out-Null
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
    if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) {
        Start-Process explorer.exe
    }
}

# ------------------------------------------------------------------------------

Assert-Elevated

if (-not $AssetsPath) { $AssetsPath = Join-Path $PSScriptRoot 'assets' }
if (-not $BackupPath) { $BackupPath = Join-Path $PSScriptRoot 'backup' }

$pkg           = Get-ClaudePackage
$versionBackup = Join-Path $BackupPath $pkg.Version
Log "Claude Desktop $($pkg.Version)" 'Cyan'
Log "Assets folder: $($pkg.Assets)"

$sourceDir = if ($Restore) { $versionBackup } else { $AssetsPath }
if (-not (Test-Path $sourceDir)) {
    if ($Restore) { throw "No backup for version $($pkg.Version) in $BackupPath - the fix was never applied to this version from here." }
    throw "Replacement assets not found: $sourceDir"
}
if (-not $Restore) { New-Item -ItemType Directory -Force -Path $versionBackup | Out-Null }

$changed = 0
foreach ($name in $IconFiles) {
    $target = Join-Path $pkg.Assets $name
    $source = Join-Path $sourceDir  $name

    if (-not (Test-Path $target)) { Log "  not present in the package, skipped: $name" 'Yellow'; continue }
    if (-not (Test-Path $source)) { Log "  not present in $sourceDir, skipped: $name" 'Yellow'; continue }

    if (Test-SameContent $source $target) { Log ("  {0,-52} already up to date" -f $name); continue }

    # Back up the pristine original of this version once, before the first overwrite.
    if (-not $Restore) {
        $backupFile = Join-Path $versionBackup $name
        if (-not (Test-Path $backupFile)) { Copy-Item -Path $target -Destination $backupFile -Force }
    }

    Unlock-File -Path $target

    # Write raw bytes rather than Copy-Item: several of these files are hard links
    # to each other inside the package, and this keeps the behaviour predictable.
    [System.IO.File]::WriteAllBytes($target, [System.IO.File]::ReadAllBytes($source))

    Log ("  {0,-52} {1,8:N0} bytes" -f $name, (Get-Item $target).Length) 'Green'
    $changed++
}

if ($changed -eq 0) {
    Log 'Nothing to change.' 'Green'
    return
}

if (-not $Restore) { Log "Originals backed up to: $versionBackup" }
Reset-ShellIconCache

Log 'Done.' 'Green'
Log 'If the taskbar still shows the old icon: unpin Claude, then pin it again, or sign out and back in.' 'Yellow'
