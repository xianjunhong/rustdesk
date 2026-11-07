$ErrorActionPreference = 'Stop'
$dogshareSdk = if ($env:DOGSHARE_SDK_ROOT) { $env:DOGSHARE_SDK_ROOT } else { $PSScriptRoot }
if (-not $env:CARGO_HOME) { $env:CARGO_HOME = Join-Path $dogshareSdk 'cargo' }
if (-not $env:RUSTUP_HOME) { $env:RUSTUP_HOME = Join-Path $dogshareSdk 'rustup' }
if (-not $env:VCPKG_ROOT) { $env:VCPKG_ROOT = Join-Path $dogshareSdk 'vcpkg' }
if (-not $env:VCPKG_INSTALLED_ROOT) { $env:VCPKG_INSTALLED_ROOT = Join-Path $env:VCPKG_ROOT 'installed' }
if (-not $env:VCPKG_DEFAULT_HOST_TRIPLET) { $env:VCPKG_DEFAULT_HOST_TRIPLET = 'x64-windows-static' }
if (-not $env:LIBCLANG_PATH) { $env:LIBCLANG_PATH = Join-Path $dogshareSdk 'llvm-15.0.6\bin' }
if (-not $env:CARGO_BUILD_JOBS) { $env:CARGO_BUILD_JOBS = '4' }
$dogshareBins = @((Join-Path $env:CARGO_HOME 'bin'), $env:LIBCLANG_PATH,
    (Join-Path $dogshareSdk 'cmake-4.3.0-windows-x86_64\bin'))
$env:PATH = ($dogshareBins -join ';') + ';' + $env:PATH
$env:VSLANG = '1033'
