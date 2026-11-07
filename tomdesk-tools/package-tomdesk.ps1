param(
    [ValidateSet('package', 'verify')][string]$Mode = 'verify',
    [string]$BuildCommand = '',
    [string]$ReuseBackendFrom = '',
    [string]$BackendCache = ''
)
$ErrorActionPreference = 'Stop'
if ($Mode -eq 'package' -and [string]::IsNullOrWhiteSpace($BuildCommand)) {
    throw 'Pass -BuildCommand with the actual successful Rust backend build command.'
}
if ($ReuseBackendFrom -and $BackendCache) {
    throw 'Choose either a previous release or a role backend cache.'
}
$dogshareNativeCommand = '"' + (Join-Path $PSScriptRoot 'native-env.cmd') + '"'
$tomdeskVsEnvironment = & $env:ComSpec /d /c $dogshareNativeCommand
if ($LASTEXITCODE -ne 0) { throw 'MSVC environment initialization failed' }
foreach ($tomdeskLine in $tomdeskVsEnvironment) {
    if ($tomdeskLine -match '^(PATH|INCLUDE|LIB|LIBPATH|WindowsSdkDir|WindowsSDKVersion|VCINSTALLDIR|VCToolsInstallDir|VSINSTALLDIR|VSCMD_VER|VSCMD_ARG_HOST_ARCH|VSCMD_ARG_TGT_ARCH)=(.*)$') {
        [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], 'Process')
    }
}
. (Join-Path $PSScriptRoot 'dogshare-env.ps1')
$tomdeskPythonArgs = @("$PSScriptRoot\package_tomdesk.py", $Mode)
if ($Mode -eq 'package') { $tomdeskPythonArgs += @('--build-command', $BuildCommand) }
if ($ReuseBackendFrom) { $tomdeskPythonArgs += @('--reuse-backend-from', $ReuseBackendFrom) }
if ($BackendCache) { $tomdeskPythonArgs += @('--backend-cache', $BackendCache) }
$dogsharePython = if ($env:DOGSHARE_PYTHON) { $env:DOGSHARE_PYTHON } else { (Get-Command python.exe -ErrorAction Stop).Source }
& $dogsharePython @tomdeskPythonArgs
exit $LASTEXITCODE
