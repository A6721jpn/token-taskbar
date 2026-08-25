Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module ScheduledTasks

$taskName = "Codex Token Taskbar"
$recoveryTaskName = "Codex Token Taskbar Recovery"
$shortcutPath = Join-Path ([Environment]::GetFolderPath("Startup")) "Codex Token Taskbar.lnk"

if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Write-Output "Removed scheduled task: $taskName"
}
else {
    Write-Output "Scheduled task was not present."
}

if (Get-ScheduledTask -TaskName $recoveryTaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $recoveryTaskName -Confirm:$false
    Write-Output "Removed scheduled task: $recoveryTaskName"
}
else {
    Write-Output "Scheduled task was not present: $recoveryTaskName"
}

if (Test-Path -LiteralPath $shortcutPath) {
    Remove-Item -LiteralPath $shortcutPath -Force
    Write-Output "Removed startup shortcut: $shortcutPath"
}
else {
    Write-Output "Startup shortcut was not present."
}
