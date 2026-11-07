@echo off
setlocal
set "DOGSHARE_VCVARS=%DOGSHARE_VCVARS64%"
if not defined DOGSHARE_VCVARS if defined VSINSTALLDIR set "DOGSHARE_VCVARS=%VSINSTALLDIR%VC\Auxiliary\Build\vcvars64.bat"
if defined DOGSHARE_VCVARS goto load_environment
set "DOGSHARE_VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "%DOGSHARE_VSWHERE%" goto missing_msvc
for /f "usebackq tokens=*" %%I in (`"%DOGSHARE_VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "DOGSHARE_VCVARS=%%I\VC\Auxiliary\Build\vcvars64.bat"
:load_environment
if not exist "%DOGSHARE_VCVARS%" goto missing_msvc
call "%DOGSHARE_VCVARS%" >nul
if errorlevel 1 exit /b %errorlevel%
set PATH
set INCLUDE
set LIB
set WindowsSDK
set VCINSTALLDIR
set VCToolsInstallDir
set VSINSTALLDIR
set VSCMD
exit /b 0
:missing_msvc
echo MSVC x64 build tools were not found. Install Visual Studio C++ tools or set DOGSHARE_VCVARS64. 1>&2
exit /b 3
