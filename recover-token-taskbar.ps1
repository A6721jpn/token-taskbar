param(
    [string]$TaskName = "Codex Token Taskbar",
    [int]$MaxFailures = 3,
    [int]$WindowMinutes = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module ScheduledTasks

function Get-TokenTaskbarProcessCount {
    return @(
        Get-CimInstance Win32_Process |
            Where-Object {
                $_.Name -eq "powershell.exe" -and
                $_.CommandLine -like "*TokenTaskbar.ps1*"
            }
    ).Count
}

function Get-RecentFailureCount {
    param(
        [string]$TaskName,
        [int]$WindowMinutes
    )

    $startTime = (Get-Date).AddMinutes(-$WindowMinutes)
    $events = Get-WinEvent -FilterHashtable @{
        LogName = "Microsoft-Windows-TaskScheduler/Operational"
        Id = 201
        StartTime = $startTime
    }

    $expectedTaskName = "\$TaskName"
    $count = 0

    foreach ($event in $events) {
        $xml = [xml]$event.ToXml()
        $taskNameValue = $null
        $resultCodeValue = $null

        foreach ($node in $xml.Event.EventData.Data) {
            if ($node.Name -eq "TaskName") {
                $taskNameValue = [string]$node.'#text'
            }
            elseif ($node.Name -eq "ResultCode") {
                $resultCodeValue = [string]$node.'#text'
            }
        }

        if ($taskNameValue -eq $expectedTaskName -and $resultCodeValue -ne "0") {
            $count++
        }
    }

    return $count
}

if (Get-TokenTaskbarProcessCount) {
    exit 0
}

$recentFailureCount = Get-RecentFailureCount -TaskName $TaskName -WindowMinutes $WindowMinutes
if ($recentFailureCount -gt $MaxFailures) {
    Write-Output "Skipping recovery for '$TaskName' after $recentFailureCount failures within $WindowMinutes minutes."
    exit 0
}

Start-ScheduledTask -TaskName $TaskName
