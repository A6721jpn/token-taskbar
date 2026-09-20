param(
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$Version = '1.1.0',
    [string]$IsccPath = ''
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$build = Join-Path $root '.build'
$dist = Join-Path $root 'dist'
New-Item -ItemType Directory -Force $build, $dist | Out-Null

# Official CPython embeddable distribution; includes its redistribution license.
$pythonVersion = '3.14.7'
$pythonHash = 'D297E5FF019966817AD8502465176139F2D3D840FA4ED84B13BED399A6AB1F15'
$archive = Join-Path $build 'python-embed.zip'
if (-not (Test-Path -LiteralPath $archive)) {
    Invoke-WebRequest "https://www.python.org/ftp/python/$pythonVersion/python-$pythonVersion-embed-amd64.zip" -OutFile $archive
}
if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $pythonHash) {
    throw 'Python runtime checksum mismatch. Remove .build/python-embed.zip and retry.'
}
Expand-Archive -LiteralPath $archive -DestinationPath (Join-Path $build 'runtime') -Force

if (-not $IsccPath) {
    $candidates = @(
        "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
        "$env:ProgramFiles\Inno Setup 7\ISCC.exe",
        "$env:LOCALAPPDATA\Programs\Inno Setup 7\ISCC.exe",
        "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe"
    )
    $IsccPath = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}
if (-not $IsccPath) { throw 'Install Inno Setup, or pass -IsccPath.' }
& $IsccPath "/DAppVersion=$Version" (Join-Path $PSScriptRoot 'TokenTaskbar.iss')
if ($LASTEXITCODE -ne 0) { throw 'Installer compilation failed.' }
$installer = Join-Path $dist "TokenTaskbar-$Version-win-x64-setup.exe"
$hash = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash.ToLowerInvariant()
"$hash  $([IO.Path]::GetFileName($installer))" | Set-Content -LiteralPath (Join-Path $dist 'SHA256SUMS.txt') -Encoding ascii
Write-Output $installer
