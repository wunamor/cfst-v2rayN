' CFST local HTTP daemon: silently serves <project-root>\data on CFST_HTTP_PORT (default 22222).
' No hardcoded absolute path here: the folder is resolved from this script's own location.
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
root = fso.GetParentFolderName(WScript.ScriptFullName)
dataDir = fso.BuildPath(root, "data")
port = shell.Environment("PROCESS")("CFST_HTTP_PORT")
If port = "" Then port = "22222"
shell.Run "cmd /c cd /d """ & dataDir & """ && python -m http.server " & port, 0, False
