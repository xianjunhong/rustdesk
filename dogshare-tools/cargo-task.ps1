$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'dogshare-env.ps1')
$dogshareCargo = Join-Path $env:CARGO_HOME 'bin\cargo.exe'
if (-not (Test-Path -LiteralPath $dogshareCargo)) { $dogshareCargo = (Get-Command cargo.exe -ErrorAction Stop).Source }
& $dogshareCargo @args
exit $LASTEXITCODE
