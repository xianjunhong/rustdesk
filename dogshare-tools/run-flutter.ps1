param([Parameter(ValueFromRemainingArguments=$true)][string[]]$FlutterArguments)
$ErrorActionPreference = 'Stop'
$dogshareSdk = if ($env:DOGSHARE_SDK_ROOT) { $env:DOGSHARE_SDK_ROOT } else { $PSScriptRoot }
$dogshareFlutterRoot = if ($env:FLUTTER_ROOT) { $env:FLUTTER_ROOT } else { Join-Path $dogshareSdk 'flutter' }
$env:PATH = (Join-Path $dogshareFlutterRoot 'bin') + ';' + $env:PATH
if (-not $env:PUB_CACHE) { $env:PUB_CACHE = Join-Path $dogshareSdk 'pub-cache' }
$env:CI = 'true'
$env:FLUTTER_SUPPRESS_ANALYTICS = 'true'
$dogshareFlutter = Join-Path $dogshareFlutterRoot 'bin\flutter.bat'
if (-not (Test-Path -LiteralPath $dogshareFlutter)) { $dogshareFlutter = (Get-Command flutter.bat -ErrorAction Stop).Source }
& $dogshareFlutter @FlutterArguments
exit $LASTEXITCODE
