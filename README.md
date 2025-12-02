# Windows Profiling Tools

`RunProfiler.ps1` uses `wpr` to collect and ETW trace of all running processes during the execution
of a command. Example usage:
```
C:RunProfiler.ps1 -Target "S:\Program Files\Swift\Toolchains\0.0.0+Asserts\usr\bin\swift.exe" hello.swift
```
This assumes:
* The current directory on `C:` is a clone of this repo.
* You're tracing the Swift compiler, built as per
  [swift-build WindowsQuickStart.md](https://github.com/compnerd/swift-build/blob/main/docs/WindowsQuickStart.md)
  (recommended build args at least `build.cmd -Windows -DebugInfo`)
* You have a source file `hello.swift` in the current directory (e.g., `S:\Temp`)

Since `wpr` needs Administrator rights, it will display a UAC prompt and then open an Administrator
PowerShell window where the actual trace collection is run. The target program is run in the
original invoking terminal.
