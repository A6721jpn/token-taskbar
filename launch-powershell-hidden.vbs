Option Explicit

Dim shell
Dim fso
Dim projectRoot
Dim powershellExe
Dim scriptPath
Dim command
Dim i

Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

If WScript.Arguments.Count = 0 Then
    WScript.Quit 1
End If

projectRoot = fso.GetParentFolderName(WScript.ScriptFullName)
powershellExe = shell.ExpandEnvironmentStrings("%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe")
scriptPath = WScript.Arguments(0)
command = QuoteArgument(powershellExe) & " -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File " & QuoteArgument(scriptPath)

For i = 1 To WScript.Arguments.Count - 1
    command = command & " " & QuoteArgument(CStr(WScript.Arguments(i)))
Next

shell.CurrentDirectory = projectRoot
shell.Run command, 0, False

Function QuoteArgument(value)
    QuoteArgument = Chr(34) & Replace(value, Chr(34), Chr(34) & Chr(34)) & Chr(34)
End Function
