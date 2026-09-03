Option Explicit

Dim shell, pythonw, scriptPath
Set shell = CreateObject("WScript.Shell")
pythonw = "C:\Users\Administrator\AppData\Local\Programs\Python\Python311\pythonw.exe"
scriptPath = "F:\Jellyfin\control-panel\control_panel.py"

shell.Run """" & pythonw & """ """ & scriptPath & """", 0, False
