Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module ScheduledTasks

$projectRoot = $PSScriptRoot
$taskName = "Codex Token Taskbar"
$recoveryTaskName = "Codex Token Taskbar Recovery"
$startupShortcutPath = Join-Path ([Environment]::GetFolderPath("Startup")) "Codex Token Taskbar.lnk"
$trayScriptPath = Join-Path $projectRoot "app\TokenTaskbar.ps1"
$recoveryScriptPath = Join-Path $projectRoot "recover-token-taskbar.ps1"
$launcherScriptPath = Join-Path $projectRoot "launch-powershell-hidden.vbs"
$wscriptExe = Join-Path $env:WINDIR "System32\wscript.exe"
$currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

if (-not (Test-Path -LiteralPath $trayScriptPath)) {
    throw "Tray script not found: $trayScriptPath"
}

if (-not (Test-Path -LiteralPath $recoveryScriptPath)) {
    throw "Recovery script not found: $recoveryScriptPath"
}

if (-not (Test-Path -LiteralPath $launcherScriptPath)) {
    throw "Launcher script not found: $launcherScriptPath"
}

if (-not (Test-Path -LiteralPath $wscriptExe)) {
    throw "wscript.exe not found: $wscriptExe"
}

$arguments = '//nologo "{0}" "{1}"' -f $launcherScriptPath, $trayScriptPath
$action = New-ScheduledTaskAction -Execute $wscriptExe -Argument $arguments -WorkingDirectory $projectRoot
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $currentUser
$trigger.Delay = "PT5M"
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Seconds 0) `
    -MultipleInstances IgnoreNew `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1)
$principal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType Interactive -RunLevel Limited
$description = "Launch Codex Token Taskbar 5 minutes after interactive logon and restart it on failure."

Register-ScheduledTask `
    -TaskName $taskName `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Principal $principal `
    -Description $description `
    -Force | Out-Null

$eventQuery = @"
<QueryList>
  <Query Id="0" Path="Microsoft-Windows-TaskScheduler/Operational">
    <Select Path="Microsoft-Windows-TaskScheduler/Operational">*[System[Provider[@Name='Microsoft-Windows-TaskScheduler'] and (EventID=201)] and EventData[Data[@Name='TaskName']='\$taskName' and Data[@Name='ResultCode']!='0']]</Select>
  </Query>
</QueryList>
"@
$recoveryArguments = '//nologo "{0}" "{1}"' -f $launcherScriptPath, $recoveryScriptPath
$currentUserSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$escapedRecoveryTaskName = [System.Security.SecurityElement]::Escape($recoveryTaskName)
$escapedCurrentUser = [System.Security.SecurityElement]::Escape($currentUser)
$escapedCurrentUserSid = [System.Security.SecurityElement]::Escape($currentUserSid)
$escapedEventQuery = [System.Security.SecurityElement]::Escape($eventQuery)
$escapedWscriptExe = [System.Security.SecurityElement]::Escape($wscriptExe)
$escapedRecoveryArguments = [System.Security.SecurityElement]::Escape($recoveryArguments)
$escapedWorkingDirectory = [System.Security.SecurityElement]::Escape($projectRoot)

$recoveryTaskXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Author>$escapedCurrentUser</Author>
    <URI>\$escapedRecoveryTaskName</URI>
  </RegistrationInfo>
  <Principals>
    <Principal id="Author">
      <UserId>$escapedCurrentUserSid</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <AllowHardTerminate>true</AllowHardTerminate>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Triggers>
    <EventTrigger>
      <Enabled>true</Enabled>
      <Subscription>$escapedEventQuery</Subscription>
    </EventTrigger>
  </Triggers>
  <Actions Context="Author">
    <Exec>
      <Command>$escapedWscriptExe</Command>
      <Arguments>$escapedRecoveryArguments</Arguments>
      <WorkingDirectory>$escapedWorkingDirectory</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
"@

$recoveryTaskXmlPath = Join-Path $env:TEMP "codex-token-taskbar-recovery-task.xml"
[System.IO.File]::WriteAllText($recoveryTaskXmlPath, $recoveryTaskXml, [System.Text.Encoding]::Unicode)

try {
    & schtasks.exe /Create /TN $recoveryTaskName /XML $recoveryTaskXmlPath /F | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to register recovery task '$recoveryTaskName'."
    }
}
finally {
    Remove-Item -LiteralPath $recoveryTaskXmlPath -Force -ErrorAction SilentlyContinue
}

$removedShortcut = $false
if (Test-Path -LiteralPath $startupShortcutPath) {
    Remove-Item -LiteralPath $startupShortcutPath -Force
    $removedShortcut = $true
}

$task = Get-ScheduledTask -TaskName $taskName
$taskTrigger = $task.Triggers | Select-Object -First 1

Write-Output "Scheduled task registered: $taskName"
Write-Output "User: $currentUser"
Write-Output "Trigger: AtLogOn + $($taskTrigger.Delay)"
Write-Output "Restart on failure: $($task.Settings.RestartCount)x / $($task.Settings.RestartInterval)"
Write-Output "Multiple instances: $($task.Settings.MultipleInstances)"
Write-Output "Execution time limit: $($task.Settings.ExecutionTimeLimit)"
Write-Output "Recovery task registered: $recoveryTaskName"
Write-Output "Startup shortcut removed: $removedShortcut"
