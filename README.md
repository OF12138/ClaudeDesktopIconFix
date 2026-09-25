# Claude Desktop Icon Fix

Replaces the taskbar / Alt-Tab icon of the **MSIX build of Claude Desktop** on Windows,
and keeps it replaced across updates.

Two reasons to use it:

- **Claude Desktop before 2.9939.2.0**: the package shipped a single **24×24** unplated
  icon. On a 150% / 200% display Windows had to upscale it, so the taskbar icon looked
  blurry while every other pinned app was crisp. This tool writes a 256×256 image into
  that asset and fixes the blur.
- **Claude Desktop 2.9939.2.0 and newer**: Anthropic fixed the resolution themselves,
  and at the same time changed the artwork. The unplated icon is now an **opaque rounded
  square**, where older versions used a **transparent star glyph**. Nothing is blurry any
  more, but if you preferred the old look, this tool puts it back.

The bundled artwork is the star glyph. You can supply any image instead.

---

## Why the taskbar icon cannot be changed the normal way

A packaged (MSIX) application does not get its shell icons from the `.exe` or from a
`.lnk` shortcut. Windows reads them from the PNG assets declared in the package manifest,
and for the taskbar and Alt-Tab it asks specifically for the **unplated** variants of
`Square44x44Logo`.

That is why the usual workarounds fail:

- **Changing a desktop shortcut's icon** only affects that `.lnk`. The taskbar button is
  bound to the package identity, not to your shortcut.
- **Right-click → Properties → Change Icon** is not offered for packaged apps at all.
- The files live under `C:\Program Files\WindowsApps\`, owned by `TrustedInstaller` and
  not writable even from an elevated prompt until you take ownership.

### What changed in 2.9939.2.0

| | before 2.9939.2.0 | 2.9939.2.0 and newer |
|---|---|---|
| unplated assets | 1 file, 24×24 | 28 files: `targetsize-16 … 256`, each with an `unplated` and a `lightunplated` variant |
| artwork | transparent star glyph | opaque rounded square |
| taskbar at 200% scaling | 24×24 upscaled to 48 → blurry | `targetsize-48_altform-unplated` → sharp |

## How the fix works

The script renders **one source image** into **every unplated asset the installed package
ships**, at exactly the size each file name asks for
(`Square44x44Logo.targetsize-48_altform-unplated.png` → 48×48, and so on). On older
packages, which have only the single 24×24 file, it writes 256×256 into that one file
instead, so Windows has something sharp to scale down from.

File names are never changed. That is what makes this safe and cheap: the shell resolves
an asset name through the package's compiled `resources.pri` index and then loads
whatever bitmap it finds on disk. Because only the bytes change:

- `resources.pri` does **not** need rebuilding with `makepri`
- the package does **not** need repacking with `makeappx` or re-signing
- the package identity is unchanged, so **your Claude login and application data are
  preserved**
- the manifest declares no `uap10:PackageIntegrity`, so Windows does not verify file
  hashes at launch

Plated assets (the Start menu tile) are left untouched.

## Requirements

- Windows 10 / 11 with the **MSIX** build of Claude Desktop
  (`Get-AppxPackage -Name Claude` returns a package). If it returns nothing you have the
  Squirrel/`.exe` build, which this does not target.
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
2. Render `assets\taskbar-icon.png` into every unplated asset, skipping any file whose
   content already matches, so running it twice is harmless.
3. Copy the originals to `backup\<version>\`, once per Claude version.
4. Take ownership of each file it writes and grant `Administrators` full control.
5. If anything changed, clear the shell icon cache and restart `explorer.exe`. Your
   screen will flicker and open File Explorer windows will close.

If the taskbar still shows the old icon afterwards, unpin Claude, pin it again, or sign
out and back in.

### Rolling back

```powershell
.\Fix-ClaudeTaskbarIcon.ps1 -Restore
```

This puts back every file recorded in `backup\<installed version>\`, so it only works on
the machine where you applied the fix. Reinstalling Claude Desktop also restores the
original icons.

## Re-apply automatically after every update

Every Claude Desktop update installs a fresh package directory with the stock icons. To
have your icon re-applied automatically, run this once from an elevated PowerShell:

```powershell
.\Install-AutoReapply.ps1
```

It registers a scheduled task named `ClaudeIconFixAutoReapply` and applies the fix to the
version installed right now.

- **Trigger:** event **400** ("deployment succeeded") in
  `Microsoft-Windows-AppXDeploymentServer/Operational`, filtered with XPath on
  `PackageDisplayName = 'Claude'`. It fires once per completed Claude install or update,
  and not for any other app. The task waits 20 seconds so the updater can relaunch Claude
  first, then runs `Fix-ClaudeTaskbarIcon.ps1 -Unattended`.
- **Cost when idle: none.** There is no polling and no resident process. The Event Log
  service evaluates the filter only for events written to that one channel.
- **Effect when it fires:** `explorer.exe` restarts once, which also closes any open File
  Explorer windows. Claude updates itself while you are idle, so you usually will not
  notice.
- The script and a copy of `assets\` are installed to
  `%ProgramData%\ClaudeDesktopIconFix\` and locked so only administrators can modify
  them, because the task runs elevated. **If you change `assets\` later, run the
  installer again** to pick up the new image.
- Log: `%ProgramData%\ClaudeDesktopIconFix\reapply.log`
- Remove: `.\Install-AutoReapply.ps1 -Uninstall`

If your Claude Desktop also sometimes quits and will not start again until you reboot,
that is a separate problem with the same updates. See
[Claude-Desktop-Update-Fix](https://github.com/OF12138/Claude-Desktop-Update-Fix).

## Using your own icon

Pass any square `.png` or `.ico` (the largest frame of an `.ico` is used):

```powershell
.\Fix-ClaudeTaskbarIcon.ps1 -SourceImage .\my-icon.ico
```

A transparent background is recommended: unplated icons are drawn straight onto the
taskbar, with no plate behind them. Use artwork that reads on both light and dark
taskbars, because the same image is written to the `unplated` and `lightunplated`
variants.

To make it the default, replace `assets\taskbar-icon.png`, and if you use the scheduled
task, run `Install-AutoReapply.ps1` again.

## What is in this repository

```
Fix-ClaudeTaskbarIcon.ps1      apply / roll back the fix
Install-AutoReapply.ps1        re-apply automatically after every update
assets/taskbar-icon.png        256x256 source artwork (the transparent star glyph)
source/claude-logo-symbol.ico  the .ico the artwork was extracted from
```

## Caveats

- **A Claude Desktop update reverts the icons.** An MSIX upgrade rewrites the whole
  package directory. Either run the script again, since it finds the new version
  automatically, or install the automatic re-apply task described above.
- The script permanently changes the owner and ACL of the files it writes from
  `TrustedInstaller` to `Administrators`. This is required to write them at all and has
  no other effect; a reinstall resets it.
- Only unplated assets are touched. The Start menu tile, splash screen, wide tile and
  store logo are left alone, so on 2.9939.2.0 and newer you get the stock rounded square
  there and your own icon on the taskbar.
- This is an unofficial community fix and is not affiliated with or endorsed by
  Anthropic. The Claude logo is a trademark of Anthropic, PBC; the artwork in `assets/`
  and `source/` is included only so the application keeps displaying its own icon after
  the fix.

## License

[MIT](LICENSE) — applies to the scripts and documentation in this repository.
