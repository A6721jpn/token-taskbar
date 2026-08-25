param(
    [string]$TaskName = "Codex Token Taskbar",
    [string]$RecoveryTaskName = "Codex Token Taskbar Recovery",
    [int]$LaunchTimeoutSeconds = 30,
    [int]$RecoveryTimeoutSeconds = 90
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module ScheduledTasks

$projectRoot = $PSScriptRoot
$launcherScriptPath = Join-Path $projectRoot "launch-powershell-hidden.vbs"
$mainScriptPath = Join-Path $projectRoot "app\TokenTaskbar.ps1"
$recoveryScriptPath = Join-Path $projectRoot "recover-token-taskbar.ps1"
$wscriptExe = Join-Path $env:WINDIR "System32\wscript.exe"

function Get-TokenTaskbarProcesses {
    Get-CimInstance Win32_Process |
        Where-Object {
            $_.Name -eq "powershell.exe" -and
            $_.CommandLine -like "*TokenTaskbar.ps1*"
        } |
        ForEach-Object {
            $process = Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue
            if (-not $process) {
                return
            }

            [pscustomobject]@{
                ProcessId = [int]$_.ProcessId
                ParentProcessId = [int]$_.ParentProcessId
                CommandLine = $_.CommandLine
                StartTime = $process.StartTime
            }
        } |
        Sort-Object StartTime
}

function Wait-ForTokenTaskbarProcess {
    param(
        [int]$TimeoutSeconds,
        [int[]]$ExcludeProcessIds = @()
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $process = Get-TokenTaskbarProcesses |
            Where-Object { $ExcludeProcessIds -notcontains $_.ProcessId } |
            Sort-Object StartTime -Descending |
            Select-Object -First 1

        if ($process) {
            return $process
        }

        Start-Sleep -Seconds 1
    } while ((Get-Date) -lt $deadline)

    return $null
}

function Assert-TaskAction {
    param(
        $Task,
        [string]$ExpectedScriptPath
    )

    $action = $Task.Actions | Select-Object -First 1
    if (-not $action) {
        throw "No action was found on the scheduled task."
    }

    if ($action.Execute -ne $wscriptExe) {
        throw "Expected action executable '$wscriptExe', found '$($action.Execute)'."
    }

    $expectedArguments = @(
        '//nologo',
        $launcherScriptPath,
        $ExpectedScriptPath
    )

    foreach ($expectedArgument in $expectedArguments) {
        if ($action.Arguments -notlike "*$expectedArgument*") {
            throw "Expected task arguments to contain '$expectedArgument', found '$($action.Arguments)'."
        }
    }

    if ($action.WorkingDirectory -ne $projectRoot) {
        throw "Expected working directory '$projectRoot', found '$($action.WorkingDirectory)'."
    }
}

function Assert-MainTaskConfiguration {
    param(
        $Task
    )

    $trigger = $Task.Triggers | Select-Object -First 1
    if (-not $trigger) {
        throw "No trigger was found on the scheduled task."
    }

    if ($trigger.Delay -ne "PT5M") {
        throw "Expected trigger delay PT5M, found '$($trigger.Delay)'."
    }

    if ($Task.Settings.RestartCount -ne 3) {
        throw "Expected RestartCount 3, found '$($Task.Settings.RestartCount)'."
    }

    if ($Task.Settings.RestartInterval -ne "PT1M") {
        throw "Expected RestartInterval PT1M, found '$($Task.Settings.RestartInterval)'."
    }

    if ($Task.Settings.MultipleInstances -ne "IgnoreNew") {
        throw "Expected MultipleInstances IgnoreNew, found '$($Task.Settings.MultipleInstances)'."
    }

    if ($Task.Settings.ExecutionTimeLimit -ne "PT0S") {
        throw "Expected ExecutionTimeLimit PT0S, found '$($Task.Settings.ExecutionTimeLimit)'."
    }

    if ($Task.Principal.LogonType -ne "Interactive") {
        throw "Expected principal LogonType Interactive, found '$($Task.Principal.LogonType)'."
    }

    if ($Task.Principal.RunLevel -ne "Limited") {
        throw "Expected principal RunLevel Limited, found '$($Task.Principal.RunLevel)'."
    }

    Assert-TaskAction -Task $Task -ExpectedScriptPath $mainScriptPath
}

function Assert-RecoveryTaskConfiguration {
    param(
        $Task
    )

    $trigger = $Task.Triggers | Select-Object -First 1
    if (-not $trigger) {
        throw "No trigger was found on the recovery task."
    }

    if ($trigger.CimClass.CimClassName -ne "MSFT_TaskEventTrigger") {
        throw "Expected an event trigger on the recovery task, found '$($trigger.CimClass.CimClassName)'."
    }

    if ($Task.Settings.MultipleInstances -ne "IgnoreNew") {
        throw "Expected MultipleInstances IgnoreNew, found '$($Task.Settings.MultipleInstances)'."
    }

    if ($Task.Settings.ExecutionTimeLimit -ne "PT0S") {
        throw "Expected ExecutionTimeLimit PT0S, found '$($Task.Settings.ExecutionTimeLimit)'."
    }

    if ($Task.Principal.LogonType -ne "InteractiveToken") {
        throw "Expected principal LogonType InteractiveToken, found '$($Task.Principal.LogonType)'."
    }

    if ($Task.Principal.RunLevel -ne "LeastPrivilege") {
        throw "Expected principal RunLevel LeastPrivilege, found '$($Task.Principal.RunLevel)'."
    }

    Assert-TaskAction -Task $Task -ExpectedScriptPath $recoveryScriptPath
}

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if (-not $task) {
    throw "Scheduled task '$TaskName' was not found."
}

$recoveryTask = Get-ScheduledTask -TaskName $RecoveryTaskName -ErrorAction SilentlyContinue
if (-not $recoveryTask) {
    throw "Recovery task '$RecoveryTaskName' was not found."
}

Assert-MainTaskConfiguration -Task $task
Assert-RecoveryTaskConfiguration -Task $recoveryTask

$existingProcesses = Get-TokenTaskbarProcesses
if ($existingProcesses) {
    $existingProcesses | ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }

    Start-Sleep -Seconds 2
}

Start-ScheduledTask -TaskName $TaskName
$initialProcess = Wait-ForTokenTaskbarProcess -TimeoutSeconds $LaunchTimeoutSeconds
if (-not $initialProcess) {
    throw "TokenTaskbar.ps1 did not start within $LaunchTimeoutSeconds seconds."
}

$killedPid = $initialProcess.ProcessId
$killTime = Get-Date
Stop-Process -Id $killedPid -Force

$restartedProcess = Wait-ForTokenTaskbarProcess -TimeoutSeconds $RecoveryTimeoutSeconds -ExcludeProcessIds @($killedPid)
if (-not $restartedProcess) {
    throw "Task did not recover within $RecoveryTimeoutSeconds seconds after killing PID $killedPid."
}

$recoverySeconds = [math]::Round((New-TimeSpan -Start $killTime -End $restartedProcess.StartTime).TotalSeconds, 1)

[pscustomobject]@{
    TaskName = $TaskName
    RecoveryTaskName = $RecoveryTaskName
    TriggerDelay = ($task.Triggers | Select-Object -First 1).Delay
    RestartCount = $task.Settings.RestartCount
    RestartInterval = $task.Settings.RestartInterval
    InitialPid = $killedPid
    RestartedPid = $restartedProcess.ProcessId
    RecoverySeconds = $recoverySeconds
} | Format-List
