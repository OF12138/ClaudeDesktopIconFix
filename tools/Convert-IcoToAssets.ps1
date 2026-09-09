<#
.SYNOPSIS
    Builds the MSIX replacement PNG assets from an .ico (or .png) source image.

.DESCRIPTION
    MSIX packages can only reference PNG assets, so an .ico has to be unpacked first.
    This script picks the largest frame out of an .ico file, re-encodes it as a
    32-bit ARGB PNG and writes the four file names that Fix-ClaudeTaskbarIcon.ps1
    expects.

    Use -Unplated to supply a different image for the taskbar / Alt-Tab icon than
    for the Start menu tile. Claude's own design does exactly that: a bare
    transparent glyph in the taskbar, a rounded coloured square on the tile.

.PARAMETER Path
    Source .ico or .png. Used for every asset unless -Unplated is given.

.PARAMETER Unplated
    Optional separate source for Square44x44Logo.targetsize-24_altform-unplated.png,
    the file the Windows taskbar actually reads.

.PARAMETER OutputPath
    Destination folder. Defaults to the repository's 'assets' folder.

.PARAMETER Size
    Edge length of the generated square PNGs. Default 256.

.EXAMPLE
    PS> .\tools\Convert-IcoToAssets.ps1 -Path .\source\claude-logo-symbol.ico

.EXAMPLE
    PS> .\tools\Convert-IcoToAssets.ps1 -Path .\tile.png -Unplated .\glyph.ico
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Path,
    [string]$Unplated,
    [string]$OutputPath,
    [int]$Size = 256
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

if (-not $OutputPath) {
    $OutputPath = Join-Path (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)) 'assets'
}
New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null

function Get-LargestFrame {
    <# Returns a Bitmap holding the biggest image inside an .ico, or the image itself for other formats. #>
    param([string]$File)

    $full = (Resolve-Path $File).Path
    if ([System.IO.Path]::GetExtension($full).ToLowerInvariant() -ne '.ico') {
        return New-Object System.Drawing.Bitmap $full
    }

    $bytes = [System.IO.File]::ReadAllBytes($full)
    $count = [BitConverter]::ToUInt16($bytes, 4)
    $best = $null; $bestEdge = -1

    for ($i = 0; $i -lt $count; $i++) {
        $entry  = 6 + $i * 16
        $w      = $bytes[$entry];     if ($w -eq 0) { $w = 256 }   # 0 means 256 in the ICO header
        $h      = $bytes[$entry + 1]; if ($h -eq 0) { $h = 256 }
        $edge   = [Math]::Min($w, $h)
        if ($edge -le $bestEdge) { continue }
        $bestEdge = $edge
        $best = [pscustomobject]@{
            Length = [BitConverter]::ToUInt32($bytes, $entry + 8)
            Offset = [BitConverter]::ToUInt32($bytes, $entry + 12)
            Width  = $w
            Height = $h
        }
    }
    if (-not $best) { throw "No icon directory entries found in $full" }
    Write-Host ("  largest frame in {0}: {1}x{2}" -f (Split-Path -Leaf $full), $best.Width, $best.Height)

    $frame = New-Object byte[] $best.Length
    [Array]::Copy($bytes, $best.Offset, $frame, 0, $best.Length)

    if ($frame[0] -eq 0x89 -and $frame[1] -eq 0x50) {
        # PNG-compressed frame (common for 256x256). GDI+ keeps reading from the
        # backing stream, so clone into a standalone bitmap before the stream dies.
        $ms = New-Object System.IO.MemoryStream (,$frame)
        try {
            $decoded = New-Object System.Drawing.Bitmap $ms
            try   { return $decoded.Clone([System.Drawing.Rectangle]::FromLTRB(0, 0, $decoded.Width, $decoded.Height),
                                          [System.Drawing.Imaging.PixelFormat]::Format32bppArgb) }
            finally { $decoded.Dispose() }
        }
        finally { $ms.Dispose() }
    }

    # Classic BMP frame: let System.Drawing.Icon do the work.
    $icon = New-Object System.Drawing.Icon ($full, $best.Width, $best.Height)
    try { return $icon.ToBitmap() } finally { $icon.Dispose() }
}

function Write-SquarePng {
    param([System.Drawing.Bitmap]$Image, [int]$Edge, [string]$Destination)

    $bmp = New-Object System.Drawing.Bitmap $Edge, $Edge, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode  = 'HighQualityBicubic'
    $g.PixelOffsetMode    = 'HighQuality'
    $g.SmoothingMode      = 'HighQuality'
    $g.CompositingQuality = 'HighQuality'
    $g.Clear([System.Drawing.Color]::Transparent)
    $g.DrawImage($Image, (New-Object System.Drawing.Rectangle 0, 0, $Edge, $Edge))
    $g.Dispose()
    $bmp.Save($Destination, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    Write-Host ("  wrote {0,-52} {1}x{1}" -f (Split-Path -Leaf $Destination), $Edge) -ForegroundColor Green
}

$plated = Get-LargestFrame -File $Path
$glyph  = if ($Unplated) { Get-LargestFrame -File $Unplated } else { $plated }

Write-SquarePng -Image $glyph  -Edge $Size -Destination (Join-Path $OutputPath 'Square44x44Logo.targetsize-24_altform-unplated.png')
Write-SquarePng -Image $plated -Edge $Size -Destination (Join-Path $OutputPath 'Square44x44Logo.png')
Write-SquarePng -Image $plated -Edge $Size -Destination (Join-Path $OutputPath 'Square44x44Logo.scale-200.png')
Write-SquarePng -Image $plated -Edge $Size -Destination (Join-Path $OutputPath 'icon.png')

if ($glyph -ne $plated) { $glyph.Dispose() }
$plated.Dispose()

Write-Host "`nAssets written to $OutputPath" -ForegroundColor Cyan
