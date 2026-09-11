' claude-preheat: run the given command with NO console window.
' A Task Scheduler console action flashes a cmd window on every tick (every
' scheduled preheat fire would pop one - observed live as periodic popups).
' This wscript shim stays in the interactive session, so BurntToast
' notifications still display - unlike an S4U principal, which would also
' hide the window but silences toasts.
' It WAITS for the child (bWaitOnReturn = True) and passes its exit code on.
' Fire-and-forget made every task look like it finished in milliseconds:
' ExecutionTimeLimit and MultipleInstances then applied to the shim rather than
' to the real pwsh, and a session woken from sleep could be judged idle and put
' back to sleep before the retry chain (up to 3 x 240s + 2 x 90s) was done.
Option Explicit
Dim sh, fso, cmd, i
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
' A missing host binary used to come back as exit 0: sh.Run raises, //B swallows
' the error, and Task Scheduler showed every fire green while nothing ran
' (a Store pwsh update had deleted the versioned folder baked into the tasks).
' Fail loudly instead - only for real paths, a bare command name still goes
' through PATH resolution below.
If WScript.Arguments.Count = 0 Then WScript.Quit 2
If InStr(WScript.Arguments(0), "\") > 0 Then
    If Not fso.FileExists(WScript.Arguments(0)) Then WScript.Quit 127
End If
cmd = ""
For i = 0 To WScript.Arguments.Count - 1
    If i > 0 Then cmd = cmd & " "
    cmd = cmd & """" & WScript.Arguments(i) & """"
Next
WScript.Quit sh.Run(cmd, 0, True)
