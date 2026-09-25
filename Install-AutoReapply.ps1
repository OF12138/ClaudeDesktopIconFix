<#
.SYNOPSIS
    Re-applies the taskbar icon fix automatically after every Claude Desktop update.

.DESCRIPTION
    Every Claude Desktop update installs a fresh package directory and brings the 24x24
    taskbar icon back. This installer registers the scheduled task
    "ClaudeIconFixAutoReapply", triggered by event 400 in
    Microsoft-Windows-AppXDeploymentServer/Operational whose PackageDisplayName is
    "Claude", i.e. the moment an install or update of Claude completes. The task runs
    Fix-ClaudeTaskbarIcon.ps1 -Unattended against the new version.

    Fix-ClaudeTaskbarIcon.ps1 and assets\ are copied to
    %ProgramData%\ClaudeDesktopIconFix and locked down so only administrators can modify
    them: the task runs elevated and must not execute files an ordinary user can edit.
    If you change assets\ later, run this installer again to pick up the new images.

    The fix is also applied once right away, to the version installed now.

    Idle cost is zero - no polling, no resident process.

.PARAMETER Uninstall
    Removes the task and %ProgramData%\ClaudeDesktopIconFix (including its backups).
    The icons currently in the package are left as they are.

.EXAMPLE
    PS> .\Install-AutoReapply.ps1
.EXAMPLE
    PS> .\Install-AutoReapply.ps1 -Uninstall
#>
[CmdletBinding()]
param([switch]$Uninstall)

$ErrorActionPreference = 'Stop'

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script from an elevated PowerShell session (Run as Administrator).'
}

$TaskName   = 'ClaudeIconFixAutoReapply'
$InstallDir = Join-Path $env:ProgramData 'ClaudeDesktopIconFix'
$Script     = Join-Path $InstallDir 'Fix-ClaudeTaskbarIcon.ps1'
$Log        = Join-Path $InstallDir 'reapply.log'

if ($Uninstall) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $InstallDir -ErrorAction SilentlyContinue
    Write-Host "Removed scheduled task '$TaskName' and $InstallDir" -ForegroundColor Green
    return
}

# 1) Install script + assets where only administrators can change them.
# The assets folder is recreated so files from earlier versions do not linger.
$assetsDir = Join-Path $InstallDir 'assets'
Remove-Item -Recurse -Force $assetsDir -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $assetsDir | Out-Null
Copy-Item -Force (Join-Path $PSScriptRoot 'Fix-ClaudeTaskbarIcon.ps1') $Script
Copy-Item -Force (Join-Path $PSScriptRoot 'assets\*.png') $assetsDir
# SYSTEM and Administrators: full control. Users: read/execute.
& icacls.exe $InstallDir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' | Out-Null

# 2) Trigger: a Claude package deployment finished successfully.
$subscription = @'
<QueryList>
  <Query Id="0" Path="Microsoft-Windows-AppXDeploymentServer/Operational">
    <Select Path="Microsoft-Windows-AppXDeploymentServer/Operational">*[System[(EventID=400)] and EventData[Data[@Name='PackageDisplayName']='Claude']]</Select>
  </Query>
</QueryList>
'@
$triggerClass = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace Root/Microsoft/Windows/TaskScheduler
$trigger = New-CimInstance -CimClass $triggerClass -ClientOnly
$trigger.Subscription = $subscription
$trigger.Delay        = 'PT20S'   # let the updater relaunch Claude first
$trigger.Enabled      = $true

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Script`" -Unattended -LogPath `"$Log`""

# Runs as the logged-on user, elevated: admin rights to write into WindowsApps, and the
# user's session so Get-AppxPackage sees Claude and explorer.exe restarts on the desktop.
$user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$taskPrincipal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -StartWhenAvailable

Register-ScheduledTask -TaskName $TaskName -Force `
    -Description 'Re-applies the 256x256 taskbar icon to Claude Desktop after each update. https://github.com/OF12138/ClaudeDesktopIconFix' `
    -Trigger $trigger -Action $action -Principal $taskPrincipal -Settings $settings | Out-Null

Write-Host "Scheduled task '$TaskName' registered (trigger: AppXDeploymentServer event 400 for Claude)." -ForegroundColor Green
Write-Host "Script: $Script"
Write-Host "Log:    $Log"

# 3) Apply to the version installed right now.
Write-Host "`nApplying the fix to the current version ..." -ForegroundColor Cyan
& $Script -LogPath $Log
