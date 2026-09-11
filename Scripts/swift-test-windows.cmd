@echo off
REM Run the Swift core test suite on Windows with the winget Swift toolchain.
REM Usage: Scripts\swift-test-windows.cmd [extra swift test args]
REM Requires: Swift.Toolchain (winget), VS 2019 Build Tools, Windows SDK 10.0.22621+.
setlocal
set "SWIFT_ROOT=%LOCALAPPDATA%\Programs\Swift"
set "PATH=%SWIFT_ROOT%\Toolchains\6.3.3+Asserts\usr\bin;%SWIFT_ROOT%\Runtimes\6.3.3\usr\bin;%PATH%"
if not defined SDKROOT set "SDKROOT=%SWIFT_ROOT%\Platforms\6.3.3\Windows.platform\Developer\SDKs\Windows.sdk\"
REM SwiftPM needs the MSVC environment for the C targets (abm_ring.c). Pin the SDK
REM version that ships stdnoreturn.h (referenced by Swift's ucrt.modulemap).
if not defined VCINSTALLDIR call "C:\Program Files (x86)\Microsoft Visual Studio\2019\BuildTools\VC\Auxiliary\Build\vcvars64.bat" 10.0.22621.0 >nul 2>&1
cd /d "%~dp0.."
swift test %*
endlocal & exit /b %errorlevel%
