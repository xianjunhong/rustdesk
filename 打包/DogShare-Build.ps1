[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('backend', 'receiver', 'controller')][string]$Action,
    [switch]$Check,
    [string]$Repo = $env:DOGSHARE_REPO,
    [string]$Tools = $env:DOGSHARE_TOOLS,
    [string]$Python = $env:DOGSHARE_PYTHON
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$workspace = Split-Path -Parent $PSScriptRoot
if (-not $Repo) { $Repo = $workspace }
if (-not $Tools) { $Tools = Join-Path $workspace 'tomdesk-tools' }
if (-not $Python) { $Python = (Get-Command python.exe -ErrorAction Stop).Source }
$env:DOGSHARE_REPO = $Repo
$env:DOGSHARE_TOOLS = $Tools
$env:DOGSHARE_PYTHON = $Python
$pwsh = Join-Path $PSHOME 'pwsh.exe'
$cacheRoot = Join-Path $PSScriptRoot 'Rust后端'
$outputRoot = Join-Path $PSScriptRoot '输出'
$logsRoot = Join-Path $PSScriptRoot '日志'
$cacheTool = Join-Path $Tools 'dogshare_backend_cache.py'
$runId = (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + $Action
$lock = $null
$transcribing = $false
$result = 1
$runLogs = $null
$backendClock = $null
$statusScript = Join-Path $PSScriptRoot 'DogShare-BuildStatus.ps1'

function Invoke-BuildStep {
    param(
        [string]$Title, [string]$Program, [string[]]$Arguments, [string]$Directory, [string]$LogName,
        [switch]$ShowStatus, [string]$RoleLabel, [Diagnostics.Stopwatch]$SessionClock
    )
    Write-Host ('--- ' + $Title + ' ---') -ForegroundColor Cyan
    if ($ShowStatus) {
        . $statusScript
        Invoke-DogShareBuildWithStatus -Title $Title -Program $Program -Arguments $Arguments -Directory $Directory -LogPath (Join-Path $runLogs $LogName) -RoleLabel $RoleLabel -SessionClock $SessionClock
        return
    }
    Push-Location -LiteralPath $Directory
    try {
        & $Program @Arguments 2>&1 |
            Tee-Object -FilePath (Join-Path $runLogs $LogName) |
            ForEach-Object { Write-Host $_ }
        $stepResult = $LASTEXITCODE
    } finally { Pop-Location }
    if ($stepResult -ne 0) { throw "$Title 失败（退出码 $stepResult），详见日志：$runLogs" }
}

function Get-BackendSnapshot {
    $raw = & $Python -B $cacheTool snapshot --repo $Repo --tools $Tools
    if ($LASTEXITCODE -ne 0) { throw '无法计算 Rust 后端源码指纹。' }
    return (($raw -join [Environment]::NewLine) | ConvertFrom-Json)
}

function Get-Backend {
    param([ValidateSet('controller', 'receiver')][string]$Role, [switch]$Force)
    $roleLabel = if ($Role -eq 'controller') { 'A 控制端 DogShare-Control' } else { 'B 被控端 DogShare-Receiver' }
    $roleClock = $null
    if ($Action -eq 'backend') {
        $roleClock = [Diagnostics.Stopwatch]::StartNew()
        Write-Host ("[阶段] $roleLabel | 正在检查后端缓存") -ForegroundColor Cyan
    }
    $pointer = Join-Path $cacheRoot "$Role-latest.json"
    if (-not $Force -and [IO.File]::Exists($pointer)) {
        try {
            $record = Get-Content -LiteralPath $pointer -Raw | ConvertFrom-Json
            $candidate = [IO.Path]::GetFullPath([string]$record.cache_directory)
            $allowed = [IO.Path]::GetFullPath((Join-Path $cacheRoot $Role)) + [IO.Path]::DirectorySeparatorChar
            if (-not $candidate.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase)) { throw '缓存目录不匹配。' }
            $checkOutput = & $Python -B $cacheTool check --repo $Repo --tools $Tools --role $Role --cache $candidate 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Host "复用已验证的 $Role Rust 后端：$candidate" -ForegroundColor Green
                if ($roleClock) {
                    $roleClock.Stop()
                    Write-Host ('[完成] {0} | 已复用缓存 | 检查耗时 {1}' -f $roleLabel,$roleClock.Elapsed.ToString('hh\:mm\:ss')) -ForegroundColor Green
                }
                return $candidate
            }
            Write-Host "已有 $Role 后端与当前源码不匹配，将重新编译。"
        } catch {
            Write-Host "已有 $Role 后端缓存不可用，将重新编译。"
        }
    }

    $snapshot = Get-BackendSnapshot
    $features = "flutter,hwcodec,tomdesk-$Role"
    Invoke-BuildStep -Title "编译 $Role Rust 后端" -Program $pwsh -Directory $Repo -LogName "rust-$Role.log" -ShowStatus:($Action -eq 'backend') -RoleLabel $roleLabel -SessionClock $backendClock -Arguments @(
        '-NoLogo', '-NoProfile', '-File', (Join-Path $Tools 'cargo-task.ps1'),
        'build', '--locked', '--offline', '--release', '--lib', '--features', $features
    )
    if ($Action -eq 'backend') { Write-Host ("[阶段] $roleLabel | 正在校验并保存后端") -ForegroundColor Cyan }
    $cache = Join-Path (Join-Path $cacheRoot $Role) ((Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 6))
    $raw = & $Python -B $cacheTool record --repo $Repo --tools $Tools --role $Role --cache $cache --expected-fingerprint $snapshot.fingerprint
    if ($LASTEXITCODE -ne 0) { throw "无法验证或保存 $Role 后端，已停止打包。" }
    $null = (($raw -join [Environment]::NewLine) | ConvertFrom-Json)
    $pointerValue = @{ role = $Role; cache_directory = $cache; created = [DateTimeOffset]::Now.ToString('o') } | ConvertTo-Json
    $temporary = $pointer + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    [IO.File]::WriteAllText($temporary, $pointerValue, [Text.UTF8Encoding]::new($false))
    [IO.File]::Move($temporary, $pointer, $true)
    Write-Host "已保存 $Role Rust 后端：$cache" -ForegroundColor Green
    if ($roleClock) {
        $roleClock.Stop()
        Write-Host ('[完成] {0} | 已编译、校验并保存 | 该端总耗时 {1}' -f $roleLabel,$roleClock.Elapsed.ToString('hh\:mm\:ss')) -ForegroundColor Green
    }
    return $cache
}

try {
    if ($PSVersionTable.PSVersion.Major -lt 7) { throw '请使用 PowerShell 7；双击本目录的 CMD 会自动选择。' }
    foreach ($directory in @($Repo, $Tools, (Join-Path $Repo 'flutter'))) {
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) { throw "目录不存在：$directory" }
    }
    foreach ($file in @(
        $pwsh, $Python, $cacheTool,
        (Join-Path $Tools 'native-env.cmd'), (Join-Path $Tools 'native-environment.json'),
        (Join-Path $Tools 'dogshare-env.ps1'),
        (Join-Path $Tools 'cargo-task.ps1'), (Join-Path $Tools 'run-flutter.ps1'),
        (Join-Path $Tools 'package-tomdesk.ps1'), (Join-Path $Tools 'verify_tomdesk_role.py'),
        (Join-Path $Tools 'verify-live-portable.py'), (Join-Path $Tools 'Logout-DogShare-B.template.cmd')
    )) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "文件不存在：$file" }
    }
    if ($Action -eq 'backend' -and -not (Test-Path -LiteralPath $statusScript -PathType Leaf)) { throw "文件不存在：$statusScript" }

    if ($Check) {
        Write-Host '检查通过：仅检查入口和编译环境路径，未编译、未打包、未修改后端缓存。' -ForegroundColor Green
        Write-Host "任务：$Action"
        Write-Host "源码：$Repo"
        Write-Host "Rust 后端缓存：$cacheRoot"
        Write-Host "EXE 输出目录：$outputRoot"
        Write-Host "日志目录：$logsRoot"
        exit 0
    }

    try {
        $lock = [IO.File]::Open((Join-Path $PSScriptRoot '.dogshare-build.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    } catch { throw '另一个 DogShare 构建任务正在运行。请等待该任务结束后再双击。' }
    foreach ($directory in @($cacheRoot, $outputRoot, $logsRoot)) {
        [void][IO.Directory]::CreateDirectory($directory)
    }
    $runLogs = Join-Path $logsRoot $runId
    [void][IO.Directory]::CreateDirectory($runLogs)
    Start-Transcript -LiteralPath (Join-Path $runLogs '流程.log') | Out-Null
    $transcribing = $true

    if ($Action -eq 'backend') { $backendClock = [Diagnostics.Stopwatch]::StartNew() }
    Write-Host '正在加载 MSVC 编译环境。' -ForegroundColor Cyan
    $nativeCommand = '"' + (Join-Path $Tools 'native-env.cmd') + '"'
    $nativeEnvironment = & $env:ComSpec /d /c $nativeCommand
    if ($LASTEXITCODE -ne 0) { throw 'MSVC 编译环境初始化失败。' }
    foreach ($line in $nativeEnvironment) {
        if ($line -match '^(PATH|INCLUDE|LIB|LIBPATH|WindowsSdkDir|WindowsSDKVersion|VCINSTALLDIR|VCToolsInstallDir|VSINSTALLDIR|VSCMD_VER|VSCMD_ARG_HOST_ARCH|VSCMD_ARG_TGT_ARCH)=(.*)$') {
            [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], 'Process')
        }
    }
    . (Join-Path $Tools 'dogshare-env.ps1')
    $env:CARGO_TARGET_DIR = Join-Path $Repo 'target'
    $env:CARGO_NET_OFFLINE = 'true'
    $env:PYTHONDONTWRITEBYTECODE = '1'

    if ($Action -eq 'backend') {
        [void](Get-Backend -Role controller)
        [void](Get-Backend -Role receiver)
        Write-Host '两个角色的 Rust 后端均已就绪：匹配缓存已复用，缺失或过期的后端已编译保存。本任务不生成 EXE。' -ForegroundColor Green
        Write-Host ('[完成] 本次总耗时 {0}' -f $backendClock.Elapsed.ToString('hh\:mm\:ss')) -ForegroundColor Green
    } else {
        $role = $Action
        $cache = Get-Backend -Role $role
        $flutter = Join-Path $Repo 'flutter'
        Invoke-BuildStep -Title '界面回归测试' -Program $pwsh -Directory $flutter -LogName 'flutter-tests.log' -Arguments @(
            '-NoLogo', '-NoProfile', '-File', (Join-Path $Tools 'run-flutter.ps1'),
            'test', '--no-pub', 'test/tomdesk_controller_login_test.dart',
            'test/tomdesk_receiver_window_test.dart', 'test/tomdesk_receiver_cm_window_test.dart'
        )
        Invoke-BuildStep -Title '编译 Windows 界面' -Program $pwsh -Directory $flutter -LogName 'flutter-build.log' -Arguments @(
            '-NoLogo', '-NoProfile', '-File', (Join-Path $Tools 'run-flutter.ps1'), 'build', 'windows', '--release', '--no-pub'
        )

        $name = if ($role -eq 'receiver') { 'DogShare-Receiver.exe' } else { 'DogShare-Control.exe' }
        $dist = Join-Path $outputRoot (($name -replace '\.exe$', '') + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
        if (Test-Path -LiteralPath $dist) { throw "输出目录已存在：$dist" }
        $env:TOMDESK_PORTABLE_NAME = $name
        $env:TOMDESK_DIST_ROOT = $dist
        $command = "cargo build --locked --offline --release --lib --features flutter,hwcodec,tomdesk-$role"
        Invoke-BuildStep -Title '生成便携 EXE' -Program $pwsh -Directory $Repo -LogName 'package.log' -Arguments @(
            '-NoLogo', '-NoProfile', '-File', (Join-Path $Tools 'package-tomdesk.ps1'),
            '-Mode', 'package', '-BuildCommand', $command, '-BackendCache', $cache
        )
        Invoke-BuildStep -Title '校验程序角色' -Program $Python -Directory $Repo -LogName 'verify-role.log' -Arguments @(
            '-B', (Join-Path $Tools 'verify_tomdesk_role.py'), $role, '--dist', $dist, '--live-subtitles'
        )
        Invoke-BuildStep -Title '校验便携包完整性' -Program $Python -Directory $Repo -LogName 'verify-portable.log' -Arguments @(
            '-B', (Join-Path $Tools 'verify-live-portable.py'), $dist, $name
        )
        $verified = & $Python -B $cacheTool check --repo $Repo --tools $Tools --role $role --cache $cache 2>&1
        if ($LASTEXITCODE -ne 0) { throw '构建期间 Rust 输入发生变化，本次包未验收；请重新运行。' }
        Write-Host '编译、打包和校验均已完成。' -ForegroundColor Green
        Write-Host ('EXE：' + (Join-Path $dist $name)) -ForegroundColor Green
    }
    $result = 0
} catch {
    Write-Host ('构建已停止：' + $_.Exception.Message) -ForegroundColor Red
    if ($runLogs) { Write-Host "日志：$runLogs" }
} finally {
    if ($backendClock) { $backendClock.Stop() }
    if ($transcribing) { Stop-Transcript | Out-Null }
    if ($lock) { $lock.Dispose() }
}
exit $result
