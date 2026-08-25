@echo off
setlocal
set "ROOT=%~dp0"
wscript.exe //nologo "%ROOT%launch-powershell-hidden.vbs" "%ROOT%app\TokenTaskbar.ps1"
endlocal
