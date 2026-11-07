@echo off
setlocal
chcp 65001 >nul
set "DOGSHARE_ACTION=controller"
set "DOGSHARE_CHECK="
set "DOGSHARE_NO_PAUSE="
set "DOGSHARE_INVALID="
set "DOGSHARE_PWSH="
set "DOGSHARE_RESULT=0"

:parse_arguments
if "%~1"=="" goto arguments_done
if /i "%~1"=="--check" goto argument_check
if /i "%~1"=="--no-pause" goto argument_no_pause
set "DOGSHARE_INVALID=1"
shift /1
goto parse_arguments

:argument_check
if defined DOGSHARE_CHECK set "DOGSHARE_INVALID=1"
set "DOGSHARE_CHECK=-Check"
shift /1
goto parse_arguments

:argument_no_pause
if defined DOGSHARE_NO_PAUSE set "DOGSHARE_INVALID=1"
set "DOGSHARE_NO_PAUSE=1"
shift /1
goto parse_arguments

:arguments_done
if defined DOGSHARE_INVALID goto usage
if defined ProgramW6432 if exist "%ProgramW6432%\PowerShell\7\pwsh.exe" set "DOGSHARE_PWSH=%ProgramW6432%\PowerShell\7\pwsh.exe"
if not defined DOGSHARE_PWSH if defined ProgramFiles if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "DOGSHARE_PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not defined DOGSHARE_PWSH goto missing_powershell
if not exist "%~dp0DogShare-Build.ps1" goto missing_builder

"%DOGSHARE_PWSH%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0DogShare-Build.ps1" -Action "%DOGSHARE_ACTION%" %DOGSHARE_CHECK%
set "DOGSHARE_RESULT=%ERRORLEVEL%"
echo.
if "%DOGSHARE_RESULT%"=="0" (echo [DogShare] Completed successfully.) else (echo [DogShare] Failed. Exit code: %DOGSHARE_RESULT%)
goto finish

:usage
echo [DogShare] Usage: "%~nx0" [--check] [--no-pause]
echo [DogShare] --check checks the build setup without building.
echo [DogShare] --no-pause returns immediately for automated calls.
set "DOGSHARE_RESULT=2"
goto finish

:missing_powershell
echo [DogShare] PowerShell 7 was not found in ProgramW6432 or ProgramFiles.
echo [DogShare] Expected: PowerShell\7\pwsh.exe
set "DOGSHARE_RESULT=9009"
goto finish

:missing_builder
echo [DogShare] Missing build script: "%~dp0DogShare-Build.ps1"
set "DOGSHARE_RESULT=3"
goto finish

:finish
if not defined DOGSHARE_NO_PAUSE pause
exit /b %DOGSHARE_RESULT%
