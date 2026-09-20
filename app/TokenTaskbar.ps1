param(
    [string]$CodexRoot = (Join-Path $env:USERPROFILE ".codex"),
    [string]$PythonExe = "",
    [int]$RefreshIntervalSeconds = 60,
    [switch]$RunOnce
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class NativeMethods
{
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern bool DestroyIcon(IntPtr handle);
}
"@

$Script:AppRoot = Split-Path -Parent $PSScriptRoot
$Script:ReaderPath = Join-Path $PSScriptRoot "read_codex_rate_limits.py"
$Script:State = [ordered]@{
    NotifyIcon      = $null
    CurrentIcon     = $null
    Timer           = $null
    ContextMenu     = $null
    Items           = @{}
    Snapshot        = $null
    Mutex           = $null
    LastLogStamp    = $null
    LastRenderKey   = $null
    LastReaderFetchAt = $null
    PythonPath      = $null
}

function Resolve-ApplicationPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CommandName
    )

    if (Test-Path -LiteralPath $CommandName -PathType Leaf) {
        return (Resolve-Path -LiteralPath $CommandName).Path
    }

    $command = Get-Command $CommandName -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $command) {
        return $null
    }

    return $command.Source
}

function Test-PythonInterpreter {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $probeToken = "CODEX_TOKEN_TASKBAR_PYTHON_OK"
    $probeCode = "import json, sqlite3, urllib.request; print('$probeToken')"
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $probeOutput = @(& $Path -X utf8 -c $probeCode 2>&1)
        $probeExitCode = $LASTEXITCODE
    }
    catch {
        return [pscustomobject]@{
            Usable = $false
            Clean = $false
        }
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    $probeLines = @(
        $probeOutput |
            ForEach-Object { [string]$_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )

    return [pscustomobject]@{
        Usable = (
            $probeExitCode -eq 0 -and
            $probeLines.Count -gt 0 -and
            $probeLines[-1].Trim() -eq $probeToken
        )
        Clean = ($probeLines.Count -eq 1 -and $probeLines[0].Trim() -eq $probeToken)
    }
}

function Resolve-PythonInterpreter {
    if (-not [string]::IsNullOrWhiteSpace($PythonExe)) {
        $explicitPath = Resolve-ApplicationPath -CommandName $PythonExe
        if (-not $explicitPath) {
            throw "Configured Python executable was not found: $PythonExe"
        }

        $probe = Test-PythonInterpreter -Path $explicitPath
        if (-not $probe.Usable) {
            throw "Configured Python executable cannot load the required standard libraries: $explicitPath"
        }

        return $explicitPath
    }

    $bundledPython = Join-Path $Script:AppRoot "runtime\python.exe"
    if (Test-Path -LiteralPath $bundledPython -PathType Leaf) {
        $probe = Test-PythonInterpreter -Path $bundledPython
        if (-not $probe.Usable) {
            throw "Bundled Python runtime is damaged. Reinstall TokenTaskbar."
        }
        return $bundledPython
    }

    $candidates = @()
    $pyLauncher = Resolve-ApplicationPath -CommandName "py.exe"
    if ($pyLauncher) {
        $registeredOutput = @(& $pyLauncher -0p 2>$null)
        foreach ($line in $registeredOutput) {
            $match = [regex]::Match([string]$line, "[A-Za-z]:\\.*python(?:3)?\.exe\s*$")
            if ($match.Success) {
                $candidate = $match.Value.Trim()
                if ($candidates -notcontains $candidate) {
                    $candidates += $candidate
                }
            }
        }
    }

    $localPythonRoot = Join-Path $env:LOCALAPPDATA "Programs\Python"
    if (Test-Path -LiteralPath $localPythonRoot -PathType Container) {
        Get-ChildItem -LiteralPath $localPythonRoot -Directory -Filter "Python*" -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending |
            ForEach-Object {
                $candidate = Join-Path $_.FullName "python.exe"
                if ((Test-Path -LiteralPath $candidate -PathType Leaf) -and $candidates -notcontains $candidate) {
                    $candidates += $candidate
                }
            }
    }

    foreach ($commandName in @("python.exe", "python3.exe")) {
        $candidate = Resolve-ApplicationPath -CommandName $commandName
        if ($candidate -and $candidates -notcontains $candidate) {
            $candidates += $candidate
        }
    }

    $noisyFallback = $null
    foreach ($candidate in $candidates) {
        $probe = Test-PythonInterpreter -Path $candidate
        if (-not $probe.Usable) {
            continue
        }

        if ($probe.Clean) {
            return $candidate
        }

        if (-not $noisyFallback) {
            $noisyFallback = $candidate
        }
    }

    if ($noisyFallback) {
        return $noisyFallback
    }

    throw "Python 3 with json, sqlite3, and urllib was not found. Install Python or pass -PythonExe with its full path."
}

function Get-LogFileSignaturePart {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $item = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if (-not $item) {
        return "missing"
    }

    return "{0}:{1}" -f $item.Length, $item.LastWriteTimeUtc.Ticks
}

function Get-CodexLogStamp {
    $dbPath = Join-Path $CodexRoot "logs_1.sqlite"
    $walPath = Join-Path $CodexRoot "logs_1.sqlite-wal"

    return "db={0};wal={1}" -f `
        (Get-LogFileSignaturePart -Path $dbPath), `
        (Get-LogFileSignaturePart -Path $walPath)
}

function Update-CachedSnapshotTiming {
    param(
        $Snapshot
    )

    if (-not $Snapshot) {
        return $Snapshot
    }

    # Reader failures intentionally return an error-only snapshot without
    # fiveHour/weekly windows. Do not apply timing updates to that shape.
    $okProperty = $Snapshot.PSObject.Properties["ok"]
    if (-not $okProperty -or $okProperty.Value -ne $true) {
        return $Snapshot
    }

    $nowUnix = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

    $observedAtProperty = $Snapshot.PSObject.Properties["observedAt"]
    if ($observedAtProperty -and $null -ne $observedAtProperty.Value) {
        $Snapshot.ageSeconds = [Math]::Max(0, [int64]$nowUnix - [int64]$observedAtProperty.Value)
    }

    foreach ($windowName in @("fiveHour", "weekly")) {
        $windowProperty = $Snapshot.PSObject.Properties[$windowName]
        if (-not $windowProperty) {
            continue
        }

        $window = $windowProperty.Value
        if (-not $window) {
            continue
        }

        $resetAtProperty = $window.PSObject.Properties["resetAt"]
        if (-not $resetAtProperty -or $null -eq $resetAtProperty.Value) {
            $window.resetInSeconds = $null
            continue
        }

        $resetAt = [int64]$resetAtProperty.Value
        $window.resetInSeconds = [Math]::Max(0, $resetAt - $nowUnix)

        if ($nowUnix -ge $resetAt) {
            if ($window.PSObject.Properties["usedPercent"]) {
                $window.usedPercent = 0
            }

            $window.remainingPercent = 100
        }
    }

    return $Snapshot
}

function Get-SnapshotFieldValue {
    param(
        $Value
    )

    if ($null -eq $Value) {
        return "<null>"
    }

    return [string]$Value
}

function Get-ObjectPropertyValue {
    param(
        $Object,
        [Parameter(Mandatory = $true)]
        [string]$PropertyName
    )

    if (-not $Object) {
        return $null
    }

    $property = $Object.PSObject.Properties[$PropertyName]
    if (-not $property) {
        return $null
    }

    return $property.Value
}

function Get-SnapshotWindowFieldValue {
    param(
        $Snapshot,
        [Parameter(Mandatory = $true)]
        [string]$WindowName,
        [Parameter(Mandatory = $true)]
        [string]$FieldName
    )

    if (-not $Snapshot) {
        return $null
    }

    $window = Get-ObjectPropertyValue -Object $Snapshot -PropertyName $WindowName
    if (-not $window) {
        return $null
    }

    return Get-ObjectPropertyValue -Object $window -PropertyName $FieldName
}

function Get-SnapshotRenderKey {
    param(
        $Snapshot
    )

    if (-not $Snapshot) {
        return "missing"
    }

    $parts = @(
        (Get-SnapshotFieldValue (Get-ObjectPropertyValue -Object $Snapshot -PropertyName "ok")),
        (Get-SnapshotFieldValue (Get-ObjectPropertyValue -Object $Snapshot -PropertyName "planType")),
        (Get-SnapshotFieldValue (Get-ObjectPropertyValue -Object $Snapshot -PropertyName "allowed")),
        (Get-SnapshotFieldValue (Get-ObjectPropertyValue -Object $Snapshot -PropertyName "limitReached")),
        (Get-SnapshotFieldValue (Get-ObjectPropertyValue -Object $Snapshot -PropertyName "observedAt")),
        (Get-SnapshotFieldValue (Get-ObjectPropertyValue -Object $Snapshot -PropertyName "error")),
        (Get-SnapshotFieldValue (Get-SnapshotWindowFieldValue -Snapshot $Snapshot -WindowName "fiveHour" -FieldName "remainingPercent")),
        (Get-SnapshotFieldValue (Get-SnapshotWindowFieldValue -Snapshot $Snapshot -WindowName "fiveHour" -FieldName "resetAt")),
        (Get-SnapshotFieldValue (Get-SnapshotWindowFieldValue -Snapshot $Snapshot -WindowName "weekly" -FieldName "remainingPercent")),
        (Get-SnapshotFieldValue (Get-SnapshotWindowFieldValue -Snapshot $Snapshot -WindowName "weekly" -FieldName "resetAt"))
    )

    return ($parts -join "|")
}

function Get-WindowPercentValue {
    param(
        [Parameter(Mandatory = $true)]
        $Window
    )

    if ($null -eq $Window) {
        return $null
    }

    $value = $Window.remainingPercent
    if ($null -eq $value) {
        return $null
    }

    return [Math]::Max(0, [Math]::Min(100, [int]$value))
}

function Get-StatusColor {
    param(
        [int]$RemainingPercent
    )

    if ($RemainingPercent -le 10) {
        return [System.Drawing.Color]::FromArgb(255, 186, 54, 63)
    }

    if ($RemainingPercent -le 30) {
        return [System.Drawing.Color]::FromArgb(255, 201, 126, 52)
    }

    if ($RemainingPercent -le 60) {
        return [System.Drawing.Color]::FromArgb(255, 154, 137, 49)
    }

    return [System.Drawing.Color]::FromArgb(255, 46, 122, 92)
}

function New-RoundedRectanglePath {
    param(
        [System.Drawing.RectangleF]$Rectangle,
        [float]$Radius
    )

    $diameter = $Radius * 2
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddArc($Rectangle.X, $Rectangle.Y, $diameter, $diameter, 180, 90)
    $path.AddArc($Rectangle.Right - $diameter, $Rectangle.Y, $diameter, $diameter, 270, 90)
    $path.AddArc($Rectangle.Right - $diameter, $Rectangle.Bottom - $diameter, $diameter, $diameter, 0, 90)
    $path.AddArc($Rectangle.X, $Rectangle.Bottom - $diameter, $diameter, $diameter, 90, 90)
    $path.CloseFigure()
    return $path
}

function Get-DigitSegments {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Character
    )

    switch ($Character) {
        "0" { return @("a", "b", "c", "d", "e", "f") }
        "1" { return @("b", "c") }
        "2" { return @("a", "b", "d", "e", "g") }
        "3" { return @("a", "b", "c", "d", "g") }
        "4" { return @("b", "c", "f", "g") }
        "5" { return @("a", "c", "d", "f", "g") }
        "6" { return @("a", "c", "d", "e", "f", "g") }
        "7" { return @("a", "b", "c") }
        "8" { return @("a", "b", "c", "d", "e", "f", "g") }
        "9" { return @("a", "b", "c", "d", "f", "g") }
        "-" { return @("g") }
        default { return @() }
    }
}

function Draw-SegmentBlock {
    param(
        [Parameter(Mandatory = $true)]
        [System.Drawing.Graphics]$Graphics,
        [Parameter(Mandatory = $true)]
        [System.Drawing.Brush]$Brush,
        [Parameter(Mandatory = $true)]
        [System.Drawing.RectangleF]$Rectangle,
        [float]$Radius = 2.0
    )

    $path = New-RoundedRectanglePath -Rectangle $Rectangle -Radius $Radius
    try {
        $Graphics.FillPath($Brush, $path)
    }
    finally {
        $path.Dispose()
    }
}

function Draw-SegmentDigit {
    param(
        [Parameter(Mandatory = $true)]
        [System.Drawing.Graphics]$Graphics,
        [Parameter(Mandatory = $true)]
        [string]$Character,
        [Parameter(Mandatory = $true)]
        [System.Drawing.RectangleF]$Bounds,
        [Parameter(Mandatory = $true)]
        [System.Drawing.Brush]$FillBrush,
        [float]$OffsetX = 0,
        [float]$OffsetY = 0
    )

    $segments = @(Get-DigitSegments -Character $Character)
    if ($segments.Count -eq 0) {
        return
    }

    $thickness = [Math]::Max(5.0, [Math]::Round([Math]::Min($Bounds.Width, $Bounds.Height) * 0.18, 1))
    $margin = [Math]::Max(2.0, [Math]::Round($thickness * 0.55, 1))
    $radius = [Math]::Max(1.6, [Math]::Round($thickness * 0.42, 1))
    $segmentGap = [Math]::Max(1.0, [Math]::Round($thickness * 0.18, 1))
    $verticalHeight = [Math]::Max(6.0, [Math]::Round((($Bounds.Height - (2 * $margin) - (3 * $thickness)) / 2.0) - $segmentGap, 1))

    $leftX = $Bounds.X + $margin + $OffsetX
    $rightX = $Bounds.Right - $margin - $thickness + $OffsetX
    $hX = $Bounds.X + $margin + ($thickness * 0.72) + $OffsetX
    $hWidth = [Math]::Max(4.0, $Bounds.Width - (2 * $margin) - (2 * $thickness * 0.72))
    $topY = $Bounds.Y + $margin + $OffsetY
    $midY = $Bounds.Y + (($Bounds.Height - $thickness) / 2.0) + $OffsetY
    $bottomY = $Bounds.Bottom - $margin - $thickness + $OffsetY
    $upperY = $topY + $thickness + $segmentGap
    $lowerY = $midY + $thickness + $segmentGap

    $segmentRects = @{
        a = [System.Drawing.RectangleF]::new($hX, $topY, $hWidth, $thickness)
        b = [System.Drawing.RectangleF]::new($rightX, $upperY, $thickness, $verticalHeight)
        c = [System.Drawing.RectangleF]::new($rightX, $lowerY, $thickness, $verticalHeight)
        d = [System.Drawing.RectangleF]::new($hX, $bottomY, $hWidth, $thickness)
        e = [System.Drawing.RectangleF]::new($leftX, $lowerY, $thickness, $verticalHeight)
        f = [System.Drawing.RectangleF]::new($leftX, $upperY, $thickness, $verticalHeight)
        g = [System.Drawing.RectangleF]::new($hX, $midY, $hWidth, $thickness)
    }

    foreach ($segment in $segments) {
        Draw-SegmentBlock -Graphics $Graphics -Brush $FillBrush -Rectangle $segmentRects[$segment] -Radius $radius
    }
}

function Draw-SegmentDisplay {
    param(
        [Parameter(Mandatory = $true)]
        [System.Drawing.Graphics]$Graphics,
        [Parameter(Mandatory = $true)]
        [string]$Text,
        [Parameter(Mandatory = $true)]
        [System.Drawing.Rectangle]$Bounds
    )

    $characters = @($Text.ToCharArray() | ForEach-Object { [string]$_ })
    $charCount = [Math]::Max(1, $characters.Count)
    $gap = switch ($charCount) {
        1 { 0.0 }
        2 { 4.0 }
        default { 2.5 }
    }

    $digitWidth = if ($charCount -eq 1) {
        [Math]::Min(34.0, [double]$Bounds.Width)
    }
    else {
        ($Bounds.Width - ($gap * ($charCount - 1))) / $charCount
    }
    $digitHeight = $Bounds.Height
    $startX = if ($charCount -eq 1) {
        $Bounds.X + (($Bounds.Width - $digitWidth) / 2.0)
    }
    else {
        $Bounds.X
    }
    $shadowBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(185, 8, 10, 14))
    $fillBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White)

    try {
        for ($index = 0; $index -lt $charCount; $index++) {
            $digitBounds = [System.Drawing.RectangleF]::new(
                $startX + ($index * ($digitWidth + $gap)),
                $Bounds.Y,
                $digitWidth,
                $digitHeight
            )

            Draw-SegmentDigit -Graphics $Graphics -Character $characters[$index] -Bounds $digitBounds -FillBrush $shadowBrush -OffsetX 1.4 -OffsetY 1.6
            Draw-SegmentDigit -Graphics $Graphics -Character $characters[$index] -Bounds $digitBounds -FillBrush $fillBrush
        }
    }
    finally {
        $fillBrush.Dispose()
        $shadowBrush.Dispose()
    }
}

function New-RateLimitIcon {
    param(
        $Snapshot
    )

    $bitmap = New-Object System.Drawing.Bitmap 64, 64
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)

    try {
        $graphics.Clear([System.Drawing.Color]::Transparent)
        $graphics.PageUnit = [System.Drawing.GraphicsUnit]::Pixel
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit

        $fiveRemaining = $null
        $weekRemaining = $null

        if ($Snapshot -and $Snapshot.ok) {
            $fiveRemaining = Get-WindowPercentValue -Window $Snapshot.fiveHour
            $weekRemaining = Get-WindowPercentValue -Window $Snapshot.weekly
        }

        $backgroundRemaining = if ($null -ne $fiveRemaining) { $fiveRemaining } else { $weekRemaining }
        $backgroundColor = if ($null -eq $backgroundRemaining) {
            [System.Drawing.Color]::FromArgb(255, 84, 92, 108)
        }
        else {
            Get-StatusColor -RemainingPercent $backgroundRemaining
        }

        $textValue = if ($null -eq $weekRemaining) { "--" } else { [string]$weekRemaining }
        $numberRect = [System.Drawing.Rectangle]::new(6, 8, 52, 46)

        $backgroundPath = New-RoundedRectanglePath -Rectangle ([System.Drawing.RectangleF]::new(1, 1, 62, 62)) -Radius 13
        $backgroundBrush = New-Object System.Drawing.SolidBrush $backgroundColor
        $borderPen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(150, 255, 255, 255), 1.1)
        $topShadeBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(24, 255, 255, 255))

        try {
            $graphics.FillPath($backgroundBrush, $backgroundPath)
            $graphics.DrawPath($borderPen, $backgroundPath)
            $graphics.FillRectangle($topShadeBrush, 4, 4, 56, 10)
        }
        finally {
            $backgroundBrush.Dispose()
            $borderPen.Dispose()
            $topShadeBrush.Dispose()
            $backgroundPath.Dispose()
        }

        Draw-SegmentDisplay -Graphics $graphics -Text $textValue -Bounds $numberRect

        $iconHandle = $bitmap.GetHicon()
        $temporaryIcon = [System.Drawing.Icon]::FromHandle($iconHandle)
        try {
            return [System.Drawing.Icon]$temporaryIcon.Clone()
        }
        finally {
            $temporaryIcon.Dispose()
            [void][NativeMethods]::DestroyIcon($iconHandle)
        }
    }
    finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

function Format-ResetLabel {
    param(
        [string]$ResetAtLocal,
        [Nullable[int]]$ResetInSeconds
    )

    if ([string]::IsNullOrWhiteSpace($ResetAtLocal)) {
        return "--"
    }

    $resetTime = [DateTimeOffset]::Parse($ResetAtLocal)
    $now = [DateTimeOffset]::Now

    if ($ResetInSeconds -le 0) {
        return "now"
    }

    if ($resetTime.Date -eq $now.Date) {
        return $resetTime.ToString("HH:mm")
    }

    return $resetTime.ToString("MM/dd HH:mm")
}

function Format-CountdownLabel {
    param(
        [Nullable[int]]$TotalSeconds
    )

    if ($null -eq $TotalSeconds) {
        return "--"
    }

    if ($TotalSeconds -le 0) {
        return "now"
    }

    $timeSpan = [TimeSpan]::FromSeconds([int]$TotalSeconds)
    if ($timeSpan.TotalDays -ge 1) {
        return ("{0}d {1}h" -f [int][Math]::Floor($timeSpan.TotalDays), $timeSpan.Hours)
    }

    if ($timeSpan.TotalHours -ge 1) {
        return ("{0}h {1}m" -f [int][Math]::Floor($timeSpan.TotalHours), $timeSpan.Minutes)
    }

    return ("{0}m" -f [Math]::Max(1, [int][Math]::Ceiling($timeSpan.TotalMinutes)))
}

function Get-TooltipText {
    param(
        $Snapshot
    )

    if (-not $Snapshot -or -not $Snapshot.ok) {
        return "Codex limits unavailable"
    }

    $fiveValue = if ($null -eq $Snapshot.fiveHour.remainingPercent) { "--" } else { [string][int]$Snapshot.fiveHour.remainingPercent }
    $weekValue = if ($null -eq $Snapshot.weekly.remainingPercent) { "--" } else { [string][int]$Snapshot.weekly.remainingPercent }
    $weekReset = Format-ResetLabel -ResetAtLocal $Snapshot.weekly.resetAtLocal -ResetInSeconds $Snapshot.weekly.resetInSeconds
    if ($fiveValue -eq "--") {
        return "Wk ${weekValue}% | reset $weekReset"
    }

    return "5h ${fiveValue}% | Wk ${weekValue}% | Wk reset $weekReset"
}

function Get-SnapshotSourceLabel {
    param(
        $Snapshot
    )

    $source = Get-ObjectPropertyValue -Object $Snapshot -PropertyName "source"
    switch ($source) {
        "backend-api/wham/usage" { return "official" }
        "logs_1.sqlite" { return "local logs" }
        default {
            if ([string]::IsNullOrWhiteSpace([string]$source)) {
                return "unknown"
            }

            return [string]$source
        }
    }
}

function Get-ReaderSnapshot {
    if (-not $Script:State.PythonPath) {
        try {
            $Script:State.PythonPath = Resolve-PythonInterpreter
        }
        catch {
            return [pscustomobject]@{
                ok    = $false
                error = $_.Exception.Message
            }
        }
    }

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $commandOutput = @(& $Script:State.PythonPath -X utf8 $Script:ReaderPath --codex-root $CodexRoot 2>&1)
        $readerExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    $joinedOutput = ($commandOutput -join [Environment]::NewLine).Trim()

    if ($readerExitCode -ne 0) {
        return [pscustomobject]@{
            ok    = $false
            error = "Reader process failed: $joinedOutput"
        }
    }

    if ([string]::IsNullOrWhiteSpace($joinedOutput)) {
        return [pscustomobject]@{
            ok    = $false
            error = "Reader process returned no output."
        }
    }

    $outputLines = @($commandOutput | ForEach-Object { [string]$_ })
    for ($index = $outputLines.Count - 1; $index -ge 0; $index--) {
        $candidateJson = $outputLines[$index].Trim()
        if ([string]::IsNullOrWhiteSpace($candidateJson)) {
            continue
        }

        try {
            return $candidateJson | ConvertFrom-Json
        }
        catch {
            continue
        }
    }

    return [pscustomobject]@{
        ok    = $false
        error = "Failed to parse reader JSON."
        raw   = $joinedOutput
    }
}

function Update-MenuText {
    param(
        $Snapshot
    )

    $items = $Script:State.Items

    if (-not $Snapshot -or -not $Snapshot.ok) {
        $items.header.Text = "Codex rate limits unavailable"
        $items.fiveHour.Text = "5h: waiting for local data"
        $items.weekly.Text = "Week: waiting for local data"
        $errorText = Get-ObjectPropertyValue -Object $Snapshot -PropertyName "error"
        if ([string]::IsNullOrWhiteSpace($errorText)) {
            $errorText = "unknown"
        }

        $items.updated.Text = "Status: $errorText"
        return
    }

    $fiveRemaining = if ($null -eq $Snapshot.fiveHour.remainingPercent) { "--" } else { [string][int]$Snapshot.fiveHour.remainingPercent + "%" }
    $weekRemaining = if ($null -eq $Snapshot.weekly.remainingPercent) { "--" } else { [string][int]$Snapshot.weekly.remainingPercent + "%" }
    $fiveReset = Format-ResetLabel -ResetAtLocal $Snapshot.fiveHour.resetAtLocal -ResetInSeconds $Snapshot.fiveHour.resetInSeconds
    $weekReset = Format-ResetLabel -ResetAtLocal $Snapshot.weekly.resetAtLocal -ResetInSeconds $Snapshot.weekly.resetInSeconds
    $fiveCountdown = Format-CountdownLabel -TotalSeconds $Snapshot.fiveHour.resetInSeconds
    $weekCountdown = Format-CountdownLabel -TotalSeconds $Snapshot.weekly.resetInSeconds
    $sourceLabel = Get-SnapshotSourceLabel -Snapshot $Snapshot

    $items.header.Text = "Codex plan: $($Snapshot.planType)"
    $items.fiveHour.Visible = ($fiveRemaining -ne "--")
    if ($items.fiveHour.Visible) {
        $items.fiveHour.Text = "5h: $fiveRemaining left | reset $fiveReset ($fiveCountdown)"
    }
    $items.weekly.Text = "Week: $weekRemaining left | reset $weekReset ($weekCountdown)"
    $items.updated.Text = "Last sync: $($Snapshot.observedAtLocal) | $sourceLabel"
}

function Update-NotifyIcon {
    param(
        $Snapshot
    )

    $notifyIcon = $Script:State.NotifyIcon
    $newIcon = New-RateLimitIcon -Snapshot $Snapshot

    $oldIcon = $Script:State.CurrentIcon
    $notifyIcon.Icon = $newIcon
    $notifyIcon.Text = Get-TooltipText -Snapshot $Snapshot
    $Script:State.CurrentIcon = $newIcon

    if ($oldIcon) {
        $oldIcon.Dispose()
    }

    Update-MenuText -Snapshot $Snapshot
}

function Invoke-Refresh {
    $snapshotSource = Get-ObjectPropertyValue -Object $Script:State.Snapshot -PropertyName "source"
    $canReuseLocalSnapshot = $false
    $nowUnix = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

    if ($snapshotSource -eq "logs_1.sqlite" -and $Script:State.Snapshot) {
        $currentLogStamp = Get-CodexLogStamp
        $secondsSinceReaderFetch = if ($null -eq $Script:State.LastReaderFetchAt) {
            [int64]::MaxValue
        }
        else {
            [int64]$nowUnix - [int64]$Script:State.LastReaderFetchAt
        }

        if ($currentLogStamp -eq $Script:State.LastLogStamp -and $secondsSinceReaderFetch -lt 300) {
            $canReuseLocalSnapshot = $true
        }
    }

    if ($canReuseLocalSnapshot) {
        $snapshot = Update-CachedSnapshotTiming -Snapshot $Script:State.Snapshot
    }
    else {
        $Script:State.LastReaderFetchAt = $nowUnix
        $snapshot = Get-ReaderSnapshot
        if ((Get-ObjectPropertyValue -Object $snapshot -PropertyName "source") -eq "logs_1.sqlite") {
            $Script:State.LastLogStamp = Get-CodexLogStamp
        }
        else {
            $Script:State.LastLogStamp = $null
        }

        $snapshot = Update-CachedSnapshotTiming -Snapshot $snapshot
    }

    $Script:State.Snapshot = $snapshot
    $renderKey = Get-SnapshotRenderKey -Snapshot $snapshot
    if ($renderKey -eq $Script:State.LastRenderKey) {
        return $false
    }

    Update-NotifyIcon -Snapshot $snapshot
    $Script:State.LastRenderKey = $renderKey
    return $true
}

function Show-DetailsBalloon {
    $snapshot = $Script:State.Snapshot
    if (-not $snapshot -or -not $snapshot.ok) {
        $Script:State.NotifyIcon.ShowBalloonTip(2500, "Codex token taskbar", "No local rate-limit data is available yet.", [System.Windows.Forms.ToolTipIcon]::Info)
        return
    }

    $fiveRemaining = if ($null -eq $snapshot.fiveHour.remainingPercent) { "--" } else { [string][int]$snapshot.fiveHour.remainingPercent + "%" }
    $weekRemaining = if ($null -eq $snapshot.weekly.remainingPercent) { "--" } else { [string][int]$snapshot.weekly.remainingPercent + "%" }
    $fiveCountdown = Format-CountdownLabel -TotalSeconds $snapshot.fiveHour.resetInSeconds
    $weekCountdown = Format-CountdownLabel -TotalSeconds $snapshot.weekly.resetInSeconds
    $message = if ($fiveRemaining -eq "--") {
        "Week left: $weekRemaining ($weekCountdown)"
    }
    else {
        "5h left: $fiveRemaining ($fiveCountdown)`nWeek left: $weekRemaining ($weekCountdown)"
    }
    $Script:State.NotifyIcon.ShowBalloonTip(3000, "Codex token taskbar", $message, [System.Windows.Forms.ToolTipIcon]::Info)
}

function Stop-Application {
    if ($Script:State.Timer) {
        $Script:State.Timer.Stop()
        $Script:State.Timer.Dispose()
        $Script:State.Timer = $null
    }

    if ($Script:State.NotifyIcon) {
        $Script:State.NotifyIcon.Visible = $false
        if ($Script:State.CurrentIcon) {
            $Script:State.CurrentIcon.Dispose()
            $Script:State.CurrentIcon = $null
        }

        $Script:State.NotifyIcon.Dispose()
        $Script:State.NotifyIcon = $null
    }

    if ($Script:State.ContextMenu) {
        $Script:State.ContextMenu.Dispose()
        $Script:State.ContextMenu = $null
    }

    if ($Script:State.Mutex) {
        $Script:State.Mutex.ReleaseMutex() | Out-Null
        $Script:State.Mutex.Dispose()
        $Script:State.Mutex = $null
    }
}

function Start-Application {
    $createdNew = $false
    $mutex = [System.Threading.Mutex]::new($true, "Local\CodexTokenTaskbarTray", [ref]$createdNew)
    if (-not $createdNew) {
        $mutex.Dispose()
        return
    }

    $Script:State.Mutex = $mutex

    $notifyIcon = New-Object System.Windows.Forms.NotifyIcon
    $contextMenu = New-Object System.Windows.Forms.ContextMenuStrip

    $items = @{
        header = $contextMenu.Items.Add("Codex rate limits")
    }
    $items.header.Enabled = $false
    [void]$contextMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    $items.fiveHour = $contextMenu.Items.Add("5h: loading...")
    $items.fiveHour.Enabled = $false

    $items.weekly = $contextMenu.Items.Add("Week: loading...")
    $items.weekly.Enabled = $false

    $items.updated = $contextMenu.Items.Add("Last sync: --")
    $items.updated.Enabled = $false

    [void]$contextMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    $refreshItem = $contextMenu.Items.Add("Refresh now")
    $refreshItem.Add_Click({
        try {
            $null = Invoke-Refresh
            Show-DetailsBalloon
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show(
                "Failed to refresh the Codex rate-limit snapshot.`n`n$($_.Exception.Message)",
                "Codex token taskbar",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
        }
    })

    $openCodexRootItem = $contextMenu.Items.Add("Open ~/.codex")
    $openCodexRootItem.Add_Click({
        Start-Process $CodexRoot
    })

    $openProjectItem = $contextMenu.Items.Add("Open project folder")
    $openProjectItem.Add_Click({
        Start-Process $Script:AppRoot
    })

    [void]$contextMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    $exitItem = $contextMenu.Items.Add("Exit")
    $exitItem.Add_Click({
        Stop-Application
        [System.Windows.Forms.Application]::Exit()
    })

    $notifyIcon.ContextMenuStrip = $contextMenu
    $notifyIcon.Visible = $true
    $notifyIcon.Text = "Codex token taskbar"
    $notifyIcon.Add_DoubleClick({
        Show-DetailsBalloon
    })

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = [Math]::Max(15, $RefreshIntervalSeconds) * 1000
    $timer.Add_Tick({
        try {
            $null = Invoke-Refresh
        }
        catch {
            $Script:State.Snapshot = [pscustomobject]@{
                ok    = $false
                error = $_.Exception.Message
            }
            Update-NotifyIcon -Snapshot $Script:State.Snapshot
        }
    })

    $Script:State.NotifyIcon = $notifyIcon
    $Script:State.ContextMenu = $contextMenu
    $Script:State.Items = $items
    $Script:State.Timer = $timer

    try {
        $null = Invoke-Refresh
    }
    catch {
        $Script:State.Snapshot = [pscustomobject]@{
            ok    = $false
            error = $_.Exception.Message
        }
        Update-NotifyIcon -Snapshot $Script:State.Snapshot
    }

    $timer.Start()
    Show-DetailsBalloon

    try {
        [System.Windows.Forms.Application]::Run()
    }
    finally {
        Stop-Application
    }
}

if ($RunOnce) {
    $snapshot = Get-ReaderSnapshot
    if (-not $snapshot.ok) {
        Write-Output "Codex rate limits unavailable: $($snapshot.error)"
        exit 1
    }

    $fiveRemaining = if ($null -eq $snapshot.fiveHour.remainingPercent) { "--" } else { [string][int]$snapshot.fiveHour.remainingPercent + "%" }
    $weekRemaining = if ($null -eq $snapshot.weekly.remainingPercent) { "--" } else { [string][int]$snapshot.weekly.remainingPercent + "%" }
    $fiveReset = Format-ResetLabel -ResetAtLocal $snapshot.fiveHour.resetAtLocal -ResetInSeconds $snapshot.fiveHour.resetInSeconds
    $weekReset = Format-ResetLabel -ResetAtLocal $snapshot.weekly.resetAtLocal -ResetInSeconds $snapshot.weekly.resetInSeconds

    if ($fiveRemaining -ne "--") {
        Write-Output "5h: $fiveRemaining left (reset $fiveReset)"
    }
    Write-Output "Week: $weekRemaining left (reset $weekReset)"
    Write-Output "Observed: $($snapshot.observedAtLocal)"
    exit 0
}

Start-Application
