# Claude Desktop Icon Fix

Fixes the blurry taskbar icon of the **MSIX build of Claude Desktop** on Windows.

If you run a high-DPI display at 150% or 200% scaling, the Claude icon in the Windows
taskbar looks soft and pixelated while every other pinned app is crisp. Replacing the
icon on the desktop shortcut does not help, and there is no setting anywhere in Windows
or in Claude to change it. This repository explains why, and ships a PowerShell script
that fixes it in about ten seconds.

---

## The problem

A packaged (MSIX) application does not get its shell icons from the `.exe` or from a
`.lnk` shortcut. Windows reads them from the PNG assets declared in the package
manifest. For the taskbar and Alt-Tab, the shell specifically asks for the
**unplated** variant of `Square44x44Logo`.

Claude Desktop's package ships exactly one unplated variant:

```
assets\Square44x44Logo.targetsize-24_altform-unplated.png     24 x 24
```

There is no `targetsize-32`, no `targetsize-48`, no `targetsize-256`. So on a 200%
display, where the taskbar wants a 48-pixel icon, Windows has nothing to do except
scale the 24×24 bitmap up by 2× — and that is the blur you are looking at.

The rest of the package is not much better. These were the sizes as shipped in
version `1.49585.0.0`:

| Asset | Shipped size | Used for |
|---|---|---|
| `Square44x44Logo.targetsize-24_altform-unplated.png` | **24 × 24** | **taskbar, Alt-Tab** |
| `Square44x44Logo.png` | 88 × 88 | Start menu tile |
| `Square44x44Logo.scale-200.png` | 88 × 88 | Start menu tile @ 200% |
| `Square150x150Logo.png` | 300 × 300 | medium tile |
| `icon.png` | 50 × 50 | package logo |

Why the usual workarounds fail:

- **Changing the desktop shortcut's icon** only affects that `.lnk`. It works — which is
  why your desktop icon is sharp — but the taskbar button is bound to the package
  identity, not to your shortcut.
- **Right-click → Properties → Change Icon** is not offered for packaged apps at all.
- The files live under `C:\Program Files\WindowsApps\`, which is owned by
  `TrustedInstaller` and is not writable even from an elevated prompt until you take
  ownership.

## The fix

Overwrite those PNG files in place with 256×256 versions, **keeping the file names
exactly as they are**.

That last part is what makes this safe and cheap. The shell resolves an asset name
through the package's compiled `resources.pri` index, then loads whatever bitmap it
finds on disk and scales it to the requested size. Because we only change the bytes
and not the names or the qualifiers:

- `resources.pri` does **not** need to be rebuilt with `makepri`
- the package does **not** need to be repacked with `makeappx` or re-signed
- the package identity is unchanged, so **your Claude login and application data are
  preserved**
- the manifest declares no `uap10:PackageIntegrity`, so Windows does not verify the
  file hashes at launch

A 256-pixel source downscaled to 48 pixels is sharp at any display scaling you are
likely to use.

## Requirements

- Windows 10 1903 / Windows 11 or newer
- The **MSIX** build of Claude Desktop (check with `Get-AppxPackage -Name Claude`).
  If that returns nothing you have the Squirrel/`.exe` installer build, which does not
  have this problem and is not what this script targets.
- An elevated PowerShell session

## Usage

```powershell
git clone https://github.com/OF12138/ClaudeDesktopIconFix.git
cd ClaudeDesktopIconFix
```

Then, from a PowerShell window started with **Run as administrator**:

```powershell
.\Fix-ClaudeTaskbarIcon.ps1
```

If script execution is blocked on your machine:

```powershell
powershell -ExecutionPolicy Bypass -File .\Fix-ClaudeTaskbarIcon.ps1
```

The script will:

1. Locate the package via `Get-AppxPackage -Name Claude`, whatever its version.
2. Skip every file that already matches the replacement, so running it twice is
   harmless.
3. Copy the originals to `backup\<version>\`, once per Claude version, so the
   backup always holds pristine files.
4. Take ownership of each file and grant `Administrators` full control.
5. Overwrite the bytes with the 256×256 assets from `assets\`.
6. If anything changed, clear the shell icon cache and restart `explorer.exe`. Your
   screen will flicker.

If the taskbar still shows the old icon afterwards, unpin Claude and pin it again, or
sign out and back in.

### Rolling back

```powershell
.\Fix-ClaudeTaskbarIcon.ps1 -Restore
```

This reads from `backup\<installed version>\`, so it only works on the machine where
you applied the fix. Reinstalling Claude Desktop also restores the original icons.

## Re-apply automatically after every update

Every Claude Desktop update installs a fresh package directory, which brings the 24×24
icon back. To have the fix re-applied automatically, run this once from an elevated
PowerShell:

```powershell
.\Install-AutoReapply.ps1
```

It registers a scheduled task named `ClaudeIconFixAutoReapply` and applies the fix to
the version installed right now.

- **Trigger:** event **400** ("deployment succeeded") in
  `Microsoft-Windows-AppXDeploymentServer/Operational`, filtered with XPath on
  `PackageDisplayName = 'Claude'`. It fires once per completed Claude install or
  update, and not for any other app. The task waits 20 seconds so the updater can
  relaunch Claude first, then runs `Fix-ClaudeTaskbarIcon.ps1 -Unattended`.
- **Cost when idle: none.** There is no polling and no resident process. The Event Log
  service evaluates the filter only for events written to that one channel.
- **Effect when it fires:** `explorer.exe` restarts once, which also closes any open
  File Explorer windows. Claude updates itself while you are idle, so you usually
  won't notice.
- The script and a copy of `assets\` are installed to
  `%ProgramData%\ClaudeDesktopIconFix\` and locked so that only administrators can
  modify them, because the task runs elevated. **If you change `assets\` later, run
  the installer again** to pick up the new images.
- Log: `%ProgramData%\ClaudeDesktopIconFix\reapply.log`
- Remove: `.\Install-AutoReapply.ps1 -Uninstall`

If your Claude Desktop also sometimes quits and will not start again until you reboot,
that is a separate problem with the same updates. See
[Claude-Desktop-Update-Fix](https://github.com/OF12138/Claude-Desktop-Update-Fix).

## Using your own icon

`assets\` holds the four PNGs the script writes. Replace them with your own — the file
names must stay exactly as they are — or generate them from an `.ico` or `.png`:

```powershell
.\tools\Convert-IcoToAssets.ps1 -Path .\my-icon.ico
```

The helper picks the largest frame in the `.ico` (handling both classic BMP frames and
PNG-compressed 256×256 frames), re-encodes it as 32-bit ARGB PNG, and writes all four
names into `assets\`.

Claude's own design uses two different images, and you can do the same: a bare
transparent glyph for the taskbar, a rounded coloured square for the Start menu tile.

```powershell
.\tools\Convert-IcoToAssets.ps1 -Path .\tile.png -Unplated .\glyph.ico
```

## What is in this repository

```
Fix-ClaudeTaskbarIcon.ps1              apply / roll back the fix
Install-AutoReapply.ps1                re-apply automatically after every update
assets/                                the 256x256 replacement PNGs
  Square44x44Logo.targetsize-24_altform-unplated.png    taskbar + Alt-Tab
  Square44x44Logo.png                                   Start menu tile
  Square44x44Logo.scale-200.png                         Start menu tile @200%
  icon.png                                              package logo
source/claude-logo-symbol.ico          the 256px source icon the assets came from
tools/Convert-IcoToAssets.ps1          build assets/ from your own .ico or .png
```

## Caveats

- **A Claude Desktop update reverts the icons.** An MSIX upgrade rewrites the whole
  package directory. Either run the script again, since it finds the new version
  automatically, or install the automatic re-apply task described above.
- The script permanently changes the owner and ACL of those four files from
  `TrustedInstaller` to `Administrators`. This is required to write them at all and
  has no other effect; a reinstall resets it.
- Only the four listed files are touched. Splash screen, wide tile and lock screen
  logo are left alone.
- This is an unofficial community fix and is not affiliated with or endorsed by
  Anthropic. The Claude logo is a trademark of Anthropic, PBC; the artwork in
  `assets/` and `source/` is included only so the application keeps displaying its own
  icon after the fix.

## License

[MIT](LICENSE) — applies to the scripts and documentation in this repository.
