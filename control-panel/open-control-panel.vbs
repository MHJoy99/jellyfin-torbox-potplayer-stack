Option Explicit

Dim shell, http, pythonw, scriptPath
Set shell = CreateObject("WScript.Shell")
pythonw = "C:\Users\Administrator\AppData\Local\Programs\Python\Python311\pythonw.exe"
scriptPath = "F:\Jellyfin\control-panel\control_panel.py"

On Error Resume Next
Set http = CreateObject("MSXML2.XMLHTTP")
http.Open "GET", "http://127.0.0.1:18080/health", False
http.Send
If Err.Number <> 0 Or http.Status <> 200 Then
  Err.Clear
  shell.Run """" & pythonw & """ """ & scriptPath & """", 0, False
  WScript.Sleep 900
End If
On Error GoTo 0

shell.Run "http://127.0.0.1:18080/", 1, False
