# Display-only support for the Rust-only entry point. All reads and host output
# run on the main PowerShell thread; no timer callbacks need a second runspace.

function Format-DogShareElapsed {
    param([TimeSpan]$Elapsed)
    return ('{0:00}:{1:00}:{2:00}' -f [int][Math]::Floor($Elapsed.TotalHours), $Elapsed.Minutes, $Elapsed.Seconds)
}

function Get-DogShareCompileActivity {
    param([int]$RootId, [hashtable]$Previous)
    try {
        $rows = @(Get-CimInstance -ClassName Win32_Process -Property Name, ProcessId, ParentProcessId -OperationTimeoutSec 1 -ErrorAction Stop)
        $ids = [Collections.Generic.HashSet[int]]::new()
        [void]$ids.Add($RootId)
        do {
            $added = $false
            foreach ($row in $rows) {
                if ($ids.Contains([int]$row.ParentProcessId) -and $ids.Add([int]$row.ProcessId)) { $added = $true }
            }
        } while ($added)
        $samples = @{}
        $workers = @()
        $delta = 0.0
        $comparable = $false
        foreach ($childId in $ids) {
            try {
                $worker = Get-Process -Id $childId -ErrorAction Stop
                $key = '{0}/{1}' -f $worker.Id, $worker.StartTime.ToUniversalTime().Ticks
                $cpu = [double]$worker.CPU
                $samples[$key] = $cpu
                if ($Previous.ContainsKey($key)) {
                    $comparable = $true
                    $delta += [Math]::Max(0.0, $cpu - [double]$Previous[$key])
                }
                $workers += [pscustomobject]@{ Name=$worker.ProcessName; Id=$worker.Id }
            } catch { continue }
        }
        $names = @($workers | ForEach-Object { $_.Name })
        $stage = if ($names -contains 'link' -or $names -contains 'lld-link') {
            '链接中'
        } elseif ($names -contains 'rustc') {
            'Rust 编译/优化中'
        } elseif ($names -contains 'cargo') {
            'Cargo 运行中'
        } else {
            '构建进程运行中'
        }
        $visible = @($workers | Where-Object { $_.Name -in @('cargo','rustc','link','lld-link','cl') })
        if (-not $visible.Count) { $visible = @($workers | Select-Object -First 1) }
        $detail = ($visible | Select-Object -First 6 | ForEach-Object { '{0}#{1}' -f $_.Name,$_.Id }) -join ', '
        return [pscustomobject]@{
            Stage=$stage; Detail=$detail; Samples=$samples; CpuDelta=$delta; Comparable=$comparable; Available=$true
        }
    } catch {
        return [pscustomobject]@{
            Stage='构建进程仍在运行'; Detail="PID $RootId，子进程状态暂不可读取"
            Samples=@{}; CpuDelta=0.0; Comparable=$false; Available=$false
        }
    }
}

function Invoke-DogShareBuildWithStatus {
    param(
        [string]$Title, [string]$Program, [string[]]$Arguments,
        [string]$Directory, [string]$LogPath, [string]$RoleLabel,
        [Diagnostics.Stopwatch]$SessionClock,
        [ValidateRange(0.1, 3600)][double]$HeartbeatSeconds = 5
    )
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $Program
    $start.WorkingDirectory = $Directory
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $start.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    # Keep the existing console association for console cancellation. Redirection
    # prevents a separate output window; finally also cleans up our child tree.
    foreach ($argument in $Arguments) { [void]$start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $writer = $null
    $started = $false
    $stepResult = $null
    $lastOutput = 0.0
    $nextHeartbeat = $HeartbeatSeconds
    $samples = @{}
    try {
        $writer = [IO.StreamWriter]::new($LogPath, $false, [Text.UTF8Encoding]::new($false))
        $writer.AutoFlush = $true
        if (-not $process.Start()) { throw "无法启动：$Program" }
        $started = $true
        $initial = '[状态] {0} | 开始编译 | 本阶段 00:00:00 | 构建 PID {1}' -f $RoleLabel,$process.Id
        Write-Host $initial -ForegroundColor Cyan
        $writer.WriteLine($initial)
        $stdout = $process.StandardOutput.ReadLineAsync()
        $stderr = $process.StandardError.ReadLineAsync()
        $outOpen = $true
        $errOpen = $true
        while ($outOpen -or $errOpen -or -not $process.HasExited) {
            $received = $false
            # Bound each drain so heavy compiler output cannot starve status.
            for ($index=0; $index -lt 128 -and $outOpen -and $stdout.IsCompleted; $index++) {
                $line = $stdout.GetAwaiter().GetResult()
                if ($null -eq $line) { $outOpen=$false; break }
                $writer.WriteLine($line)
                Write-Host $line
                $lastOutput=$clock.Elapsed.TotalSeconds
                $received=$true
                $stdout=$process.StandardOutput.ReadLineAsync()
            }
            for ($index=0; $index -lt 128 -and $errOpen -and $stderr.IsCompleted; $index++) {
                $line = $stderr.GetAwaiter().GetResult()
                if ($null -eq $line) { $errOpen=$false; break }
                $writer.WriteLine($line)
                Write-Host $line
                $lastOutput=$clock.Elapsed.TotalSeconds
                $received=$true
                $stderr=$process.StandardError.ReadLineAsync()
            }
            if (-not $process.HasExited -and $clock.Elapsed.TotalSeconds -ge $nextHeartbeat) {
                $activity = Get-DogShareCompileActivity -RootId $process.Id -Previous $samples
                $samples = $activity.Samples
                $cpu = if (-not $activity.Available) { 'CPU状态暂不可读' }
                    elseif (-not $activity.Comparable) { 'CPU首次采样' }
                    elseif ($activity.CpuDelta -ge 0.05) { 'CPU继续工作，较上次 +{0:N2}s' -f $activity.CpuDelta }
                    else { '较上次暂未观测到明显CPU增长' }
                $total = if ($null -ne $SessionClock) { Format-DogShareElapsed $SessionClock.Elapsed } else { Format-DogShareElapsed $clock.Elapsed }
                $status = '[状态 {0}] {1} | {2} | 本阶段 {3} / 总计 {4} | {5} | {6:N0}s无新日志 | {7}' -f (
                    Get-Date -Format 'HH:mm:ss'),$RoleLabel,$activity.Stage,(Format-DogShareElapsed $clock.Elapsed),$total,$cpu,(
                    [Math]::Max(0,$clock.Elapsed.TotalSeconds-$lastOutput)),$activity.Detail
                Write-Host $status -ForegroundColor Cyan
                $writer.WriteLine($status)
                $nextHeartbeat=$clock.Elapsed.TotalSeconds+$HeartbeatSeconds
            }
            if (-not $received) { [Threading.Thread]::Sleep(100) }
        }
        $process.WaitForExit()
        $stepResult=$process.ExitCode
        $state=if ($stepResult -eq 0) { '编译完成' } else { "编译失败，退出码 $stepResult" }
        $complete='[状态] {0} | {1} | 本阶段耗时 {2}' -f $RoleLabel,$state,(Format-DogShareElapsed $clock.Elapsed)
        Write-Host $complete -ForegroundColor $(if ($stepResult -eq 0) { 'Green' } else { 'Red' })
        $writer.WriteLine($complete)
    } finally {
        if ($started) {
            try {
                if (-not $process.HasExited) {
                    $process.Kill($true)
                    [void]$process.WaitForExit(5000)
                }
            } catch { Write-Host '未能确认本次启动的构建子进程已退出，请检查本次构建日志。' -ForegroundColor Yellow }
        }
        if ($writer) { $writer.Dispose() }
        $process.Dispose()
        $clock.Stop()
    }
    if ($stepResult -ne 0) { throw "$Title 失败（退出码 $stepResult），详见日志：$LogPath" }
}
