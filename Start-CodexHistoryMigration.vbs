Option Explicit

Dim shell, fileSystem, scriptDirectory, powershellPath, uiScriptPath, command

Set shell = CreateObject("WScript.Shell")
Set fileSystem = CreateObject("Scripting.FileSystemObject")

scriptDirectory = fileSystem.GetParentFolderName(WScript.ScriptFullName)
powershellPath = shell.ExpandEnvironmentStrings("%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe")
uiScriptPath = fileSystem.BuildPath(scriptDirectory, "CodexHistoryMigration.UI.ps1")

If Not fileSystem.FileExists(uiScriptPath) Then
    MsgBox "CodexHistoryMigration.UI.ps1 was not found next to the launcher.", 16, "Codex Session Manager"
    WScript.Quit 1
End If

command = Chr(34) & powershellPath & Chr(34) & _
    " -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File " & _
    Chr(34) & uiScriptPath & Chr(34)

shell.Run command, 0, False
