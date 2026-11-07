@echo off
setlocal
set "TOMDESK_LOGOUT_SCRIPT=%~f0"
set "TOMDESK_LOGOUT_MODE=%~1"
set "TOMDESK_LOGOUT_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "TOMDESK_LOGOUT_PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
"%TOMDESK_LOGOUT_PS%" -NoLogo -NoProfile -NonInteractive -Command "$lines=[IO.File]::ReadAllLines($env:TOMDESK_LOGOUT_SCRIPT); $marker=[Array]::IndexOf($lines,'# BEGIN TOMDESK POWERSHELL'); if ($marker -lt 0) { exit 3 }; & ([ScriptBlock]::Create(($lines[($marker+1)..($lines.Length-1)] -join [Environment]::NewLine)))"
set "TOMDESK_LOGOUT_RESULT=%ERRORLEVEL%"
if "%~1"=="" pause
exit /b %TOMDESK_LOGOUT_RESULT%
# BEGIN TOMDESK POWERSHELL
$ErrorActionPreference = 'Stop'

# A and B can both run as DogShare.exe. Never stop by name alone.
$receiverCore = '__DOGSHARE_RECEIVER_CORE__'
$controllerCore = 'C9291E36158E53C3A5E3D1A7784824346EF152E5AA4D00A9E9DF93A83C7607AE'
$controllerRunner = 'B81FFEC8D79F2D6ED751EA2E62ED3FC162D75AFDDC213803BB402D952FEDD2CF'
$pairedIconRunners = @('__DOGSHARE_RUNNER__')
$receiverRunners = @(
    '80C844612F06CB313BFF06BD894917F117B19B8F5CB98CD1FEE9098F2041A4BC',
    'A13D12D2FD4CE9545FA72FE7D1BCEA179DA699ECA8EC59693DAB100EF0E7A4A5',
    'B7EB2D87FD8B5208C821CC57CDF5B0B18A857F949A6F5769EDE3A6A114F4B9E0',
    'A9E90F885587B7EBC1D2499978883AF30C07F7F2AE4E034EB06C65557FC157FA'
)
$receiverWrappers = @('__DOGSHARE_WRAPPER__')

function Get-Sha256([string]$path) {
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $stream = [IO.File]::OpenRead($path)
        try { return [BitConverter]::ToString($algorithm.ComputeHash($stream)).Replace('-', '') }
        finally { $stream.Dispose() }
    } finally { $algorithm.Dispose() }
}

function Get-DogShareProcesses {
    $session = [Diagnostics.Process]::GetCurrentProcess().SessionId
    foreach ($process in Get-Process -Name 'DogShare','DogShare-Receiver' -ErrorAction SilentlyContinue) {
        if ($process.SessionId -ne $session) { continue }
        try {
            if ($process.HasExited) { continue }
            if (-not $process.Path) { throw 'Unknown path' }
            $image = [IO.Path]::GetFullPath($process.Path)
            $imageHash = Get-Sha256 $image
            if ($receiverWrappers -contains $imageHash) {
                [pscustomobject]@{ Process = $process; Role = 'B'; Runner = '' }
                continue
            }
            $core = @($process.Modules | Where-Object ModuleName -ieq 'librustdesk.dll')
            if ($core.Count -ne 1) { throw 'Unknown core' }
            $expected = Join-Path ([IO.Path]::GetDirectoryName($image)) 'librustdesk.dll'
            if ($core[0].FileName -ine $expected) { throw 'Unexpected core path' }
            $coreHash = Get-Sha256 $expected
            if ($coreHash -eq $receiverCore) {
                [pscustomobject]@{ Process = $process; Role = 'B'; Runner = $image }
            } elseif ($coreHash -eq $controllerCore) {
                [pscustomobject]@{ Process = $process; Role = 'A'; Runner = $image }
            } else { throw 'Unknown core build' }
        } catch {
            if (-not $process.HasExited) {
                [pscustomobject]@{ Process = $process; Role = '?'; Runner = '' }
            }
        }
    }
}

function Get-DeviceIdentity($processes) {
    $local = [Environment]::GetFolderPath('LocalApplicationData')
    $candidates = @($processes | Sort-Object Role -Descending | ForEach-Object { $_.Runner } | Where-Object { $_ })
    $candidates += Join-Path $local 'DogShare\DogShare.exe'
    $exe = $null
    foreach ($candidate in $candidates | Select-Object -Unique) {
        try {
            $runnerHash = Get-Sha256 $candidate
            # A/B share the local DogShare ID. A may have replaced the extracted
            # runner; a verified A runner may answer --get-id without opening UI.
            if ($pairedIconRunners -contains $runnerHash) { $expectedCores = @($receiverCore, $controllerCore) }
            elseif ($receiverRunners -contains $runnerHash) { $expectedCores = @($receiverCore) }
            elseif ($runnerHash -eq $controllerRunner) { $expectedCores = @($controllerCore) }
            else { continue }
            $core = Join-Path ([IO.Path]::GetDirectoryName($candidate)) 'librustdesk.dll'
            if ($expectedCores -contains (Get-Sha256 $core)) { $exe = $candidate; break }
        } catch { continue }
    }
    if (-not $exe) { throw 'No verified DogShare runtime for device identity' }

    $hklm = [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine', 'Registry64')
    try {
        $key = $hklm.OpenSubKey('SOFTWARE\Microsoft\Cryptography')
        if (-not $key) { throw 'No machine identity' }
        try { $machine = ([string]$key.GetValue('MachineGuid')).Trim() }
        finally { $key.Dispose() }
    } finally { $hklm.Dispose() }
    if (-not $machine) { throw 'No machine identity' }

    $start = [Diagnostics.ProcessStartInfo]::new($exe, '--get-id')
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.WorkingDirectory = [IO.Path]::GetDirectoryName($exe)
    $query = [Diagnostics.Process]::Start($start)
    try {
        $output = $query.StandardOutput.ReadToEndAsync()
        $discard = $query.StandardError.ReadToEndAsync()
        if (-not $query.WaitForExit(5000)) { $query.Kill(); throw 'Device ID query timed out' }
        if ($query.ExitCode -ne 0 -or -not $output.Wait(1000)) { throw 'Device ID query failed' }
        $id = $output.Result.Trim()
        if ($id -cnotmatch '^[A-Za-z0-9_-]{3,64}$') { throw 'Invalid device ID' }
        return @{ id = $id; uuid = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($machine)) }
    } finally { $query.Dispose() }
}

function Read-ProtectedBytes([byte[]]$bytes, [string]$magic, [string]$entropy) {
    if ($bytes.Length -le 5 -or $bytes.Length -gt 16384 -or
        [Text.Encoding]::ASCII.GetString($bytes, 0, 4) -cne $magic -or $bytes[4] -ne 1) {
        throw 'Unknown credential format'
    }
    $encrypted = [byte[]]::new($bytes.Length - 5)
    [Array]::Copy($bytes, 5, $encrypted, 0, $encrypted.Length)
    return ,([Security.Cryptography.ProtectedData]::Unprotect(
        $encrypted, [Text.Encoding]::UTF8.GetBytes($entropy), 'CurrentUser'))
}

function Test-ReceiverToken([byte[]]$marker, [byte[]]$secret) {
    if (-not $marker) { return $false }
    try {
        $digest = Read-ProtectedBytes $marker 'TDVC' 'TomDesk B voice consent v1'
        $sha = [Security.Cryptography.SHA256]::Create()
        try { return [Convert]::ToBase64String($digest) -ceq [Convert]::ToBase64String($sha.ComputeHash($secret)) }
        finally { $sha.Dispose() }
    } catch { return $false }
}

function Invoke-AccountRequest($client, [string]$endpoint, [string]$token, $identity) {
    # The paired client uses this fixed HTTPS origin. Do not follow redirects.
    $request = [Net.Http.HttpRequestMessage]::new('POST', "https://phenoseed.com/tomdesk-paired-account/api/$endpoint")
    try {
        $request.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $token)
        $request.Content = [Net.Http.StringContent]::new(($identity | ConvertTo-Json -Compress), [Text.Encoding]::UTF8, 'application/json')
        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        try {
            if (-not $response.IsSuccessStatusCode) { throw 'Account service did not confirm the request' }
            return ($response.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json)
        } finally { $response.Dispose() }
    } finally { $request.Dispose() }
}

function Remove-UnchangedFile([string]$path, [byte[]]$original) {
    if (-not [IO.File]::Exists($path)) { return $true }
    if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($path)) -cne [Convert]::ToBase64String($original)) { return $false }
    [IO.File]::Delete($path)
    return $true
}

# RUN TOMDESK LOGOUT
if ($receiverCore.StartsWith('__')) {
    Write-Host '这是构建模板，请使用 DogShare B 发布目录中的 Logout-DogShare-B.cmd。'
    exit 2
}
$mode = $env:TOMDESK_LOGOUT_MODE
if ($mode -and $mode -notin @('--check', '--no-pause')) {
    Write-Host '用法：Logout-DogShare-B.cmd [--check | --no-pause]'
    exit 2
}
$config = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'TomDesk\config'
$tokenFile = Join-Path $config 'TomDesk_paired_account.bin'
$markerFile = Join-Path $config 'TomDesk_paired_voice_consent.bin'
$processes = @(Get-DogShareProcesses)
$receivers = @($processes | Where-Object Role -eq 'B')
if ($mode -eq '--check') {
    Write-Host '仅检查：不读取登录凭据、不联网、不关闭程序。'
    Write-Host ('已确认的 B 端进程：{0}；无法确认的进程：{1}。' -f $receivers.Count, @($processes | Where-Object Role -eq '?').Count)
    Write-Host ('本机有配对登录凭据：{0}（A/B 共用，实际执行时才确认账号角色）。' -f [IO.File]::Exists($tokenFile))
    exit 0
}

$exitCode = 0
$receiverToken = $false
$controllerToken = $false
$onlineLogout = $false
$tokenBytes = $markerBytes = $plain = $token = $null
if ([IO.File]::Exists($tokenFile)) {
    try {
        Add-Type -AssemblyName System.Security
        $tokenBytes = [IO.File]::ReadAllBytes($tokenFile)
        if ([IO.File]::Exists($markerFile)) { $markerBytes = [IO.File]::ReadAllBytes($markerFile) }
        $plain = Read-ProtectedBytes $tokenBytes 'TDAC' 'TomDesk account token v1'
        $token = [Text.Encoding]::ASCII.GetString($plain)
        if ($token -cnotmatch '^[A-Za-z0-9_-]{43}$') { throw 'Unknown token format' }
        $receiverToken = Test-ReceiverToken $markerBytes $plain
        $identity = Get-DeviceIdentity $processes
        Add-Type -AssemblyName System.Net.Http
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $handler = [Net.Http.HttpClientHandler]::new()
        $handler.AllowAutoRedirect = $false
        $handler.UseCookies = $false
        $client = [Net.Http.HttpClient]::new($handler)
        try {
            $client.Timeout = [TimeSpan]::FromSeconds(7)
            if (-not $receiverToken) {
                $user = Invoke-AccountRequest $client 'currentUser' $token $identity
                $receiverToken = $user.role -ceq 'receiver'
                $controllerToken = $user.role -ceq 'controller'
            }
            if ($receiverToken) {
                $reply = Invoke-AccountRequest $client 'logout' $token $identity
                $onlineLogout = ($reply.success -is [bool]) -and $reply.success
            }
        } finally { $client.Dispose() }
    } catch {
        # Never print exceptions that could contain credentials or device identifiers.
    } finally {
        if ($plain) { [Array]::Clear($plain, 0, $plain.Length) }
        $token = $null
    }
    if ($controllerToken) {
        Write-Host '本机保存的是 A 账号，已保留 A 的登录。'
    } elseif (-not $receiverToken) {
        Write-Host '未确认本机保存的是 B 账号，登录凭据未动。'
        $exitCode = 1
    }
} else { Write-Host '本机没有已保存的配对登录。' }

# Stop verified B only. B's window close button can minimize instead of exiting.
$processes = @(Get-DogShareProcesses)
$receivers = @($processes | Where-Object Role -eq 'B' | Sort-Object { [bool]$_.Runner })
foreach ($entry in $receivers) {
    $process = $entry.Process
    try {
        if (-not $process.HasExited) {
            $process.Kill()
            if (-not $process.WaitForExit(5000)) { throw 'Exit timed out' }
        }
    } catch {
        Write-Host ('无法关闭 B 端进程 PID {0}。' -f $process.Id)
        $exitCode = 1
    }
}
if (@($processes | Where-Object Role -eq '?').Count) {
    Write-Host '有 DogShare 进程无法确认是 B，已跳过。'
    $exitCode = 1
}
if ($receivers.Count -and -not @($receivers | Where-Object { -not $_.Process.HasExited }).Count) {
    Write-Host '已关闭 B 端程序，当前远控连接已结束。'
} elseif (-not $receivers.Count) { Write-Host '没有找到正在运行的已知 B 端。' }

if ($receiverToken) {
    try {
        if (-not (Remove-UnchangedFile $tokenFile $tokenBytes)) { throw 'The saved login changed' }
        if ($markerBytes -and -not [IO.File]::Exists($tokenFile)) {
            [void](Remove-UnchangedFile $markerFile $markerBytes)
        }
        if ($onlineLogout) { Write-Host 'B 账号已退出，服务器已确认。重新打开 B 时需要登录。' }
        else {
            Write-Host 'B 已退出本机登录，但服务器未确认注销。需要立即撤销服务端会话时，可在后台踢 B 单端。'
            $exitCode = 1
        }
    } catch {
        Write-Host '本机登录凭据已变化或无法清除，请打开 B 确认登录状态。'
        $exitCode = 1
    }
}
exit $exitCode
