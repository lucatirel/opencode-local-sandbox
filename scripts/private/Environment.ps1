function Install-SbxIfMissing {
    if (Get-Command sbx -ErrorAction SilentlyContinue) { return }
    Assert-Command 'winget'
    Write-Host '[1/4] Installing Docker Sandboxes CLI for this user...' -ForegroundColor Cyan
    Invoke-External 'winget' @('install', '--exact', '--id', 'Docker.sbx', '--source', 'winget', '--accept-package-agreements', '--accept-source-agreements') | Out-Null
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
    Assert-Command 'sbx'
}

function Test-SbxDaemonPipe {
    # Probe the daemon without triggering CLI auto-start or conflating login with health.
    $Pipe = New-Object IO.Pipes.NamedPipeClientStream('.', 'docker_kaname_sandboxd', [IO.Pipes.PipeDirection]::InOut)
    try { $Pipe.Connect(500); return $Pipe.IsConnected }
    catch { return $false }
    finally { $Pipe.Dispose() }
}

function Start-OcboxSbxDaemon {
    if (Test-SbxDaemonPipe) { return }
    $Logs = Join-Path (Get-ToolRoot) '.local\logs'
    New-Item -ItemType Directory -Force -Path $Logs | Out-Null
    $Stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $OutLog = Join-Path $Logs "daemon-$Stamp.stdout.log"
    $ErrLog = Join-Path $Logs "daemon-$Stamp.stderr.log"
    Write-Host '    Starting sandbox daemon in the background...' -ForegroundColor Cyan
    $Process = Start-Process -FilePath (Get-Command sbx).Source -ArgumentList @('daemon', 'start') -WindowStyle Hidden -RedirectStandardOutput $OutLog -RedirectStandardError $ErrLog -PassThru
    $Watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        while ($Watch.Elapsed.TotalSeconds -lt 45) {
            if (Test-SbxDaemonPipe) { return }
            if ($Process.HasExited) { break }
            Write-Progress -Id 20 -Activity 'Starting Docker Sandboxes' -Status ("{0:n0}s elapsed" -f $Watch.Elapsed.TotalSeconds) -PercentComplete -1
            Start-Sleep -Milliseconds 500
        }
        $Detail = (Get-Content -LiteralPath $ErrLog -Tail 15 -ErrorAction SilentlyContinue) -join "`n"
        throw "Docker Sandbox daemon did not become reachable. $Detail`nLogs: $Logs`nRun 'sbx diagnose'; Windows Hypervisor Platform must be enabled for local microVMs."
    }
    finally { Write-Progress -Id 20 -Activity 'Starting Docker Sandboxes' -Completed }
}

function Assert-SbxSshDisabled {
    $Result = Invoke-NativeCapture 'sbx' @('settings', 'get', 'ssh.agentForwardingEnabled')
    if ($Result.Code -ne 0 -or $Result.Text.Trim() -ne 'false') {
        throw "Host SSH agent forwarding is not verifiably disabled. $($Result.Text)"
    }
}

function Initialize-SbxEnvironment {
    Install-SbxIfMissing
    Write-Host '[1/4] Docker Sandboxes daemon' -ForegroundColor Cyan
    Start-OcboxSbxDaemon
    $Version = Invoke-NativeCapture 'sbx' @('version')
    if ($Version.Code -ne 0 -or $Version.Text -notmatch 'v(\d+\.\d+\.\d+)') { throw "Cannot read sbx version: $($Version.Text)" }
    if ([version]$Matches[1] -lt [version]'0.48.0') { throw 'OCBox requires sbx 0.48.0 or later. Update with: winget upgrade --exact --id Docker.sbx' }

    Write-Host '[2/4] Docker authentication' -ForegroundColor Cyan
    $List = Invoke-NativeCapture 'sbx' @('ls', '-q')
    if ($List.Code -ne 0) {
        if ($List.Text -notmatch '(?i)auth|login|sign.?in|token|credential|session') {
            throw "Cannot query Docker Sandboxes: $($List.Text)`nRun 'sbx diagnose'."
        }
        # OAuth must run on the interactive host, never inside a validation job.
        Invoke-External 'sbx' @('login') | Out-Null
        $List = Invoke-NativeCapture 'sbx' @('ls', '-q')
        if ($List.Code -ne 0) { throw "Docker Sandboxes is not ready after login: $($List.Text)" }
    }

    Write-Host '[3/4] Disable host SSH agent forwarding (persistent sbx setting)' -ForegroundColor Cyan
    $Forwarding = Invoke-NativeCapture 'sbx' @('settings', 'get', 'ssh.agentForwardingEnabled')
    if ($Forwarding.Code -ne 0 -or $Forwarding.Text.Trim() -notin @('true', 'false')) { throw "Cannot read SSH forwarding setting: $($Forwarding.Text)" }
    if ($Forwarding.Text.Trim() -eq 'true') {
        Write-Host '    This disables forwarding across local sandboxes and restarts their daemon.' -ForegroundColor Yellow
        Invoke-External 'sbx' @('settings', 'set', 'ssh.agentForwardingEnabled', 'false') | Out-Null
        # Detect environment overrides before restarting anything.
        Assert-SbxSshDisabled
        Invoke-External 'sbx' @('daemon', 'stop') | Out-Null
        $Deadline = (Get-Date).AddSeconds(15)
        while ((Test-SbxDaemonPipe) -and (Get-Date) -lt $Deadline) { Start-Sleep -Milliseconds 300 }
        if (Test-SbxDaemonPipe) { throw 'The sandbox daemon did not stop; refusing to start the agent with uncertain SSH forwarding.' }
        Start-OcboxSbxDaemon
    }
    Assert-SbxSshDisabled

    Write-Host '[4/4] Initialize deny-by-default networking if not configured' -ForegroundColor Cyan
    # init is one-time and does not overwrite an existing global policy. Never reset it.
    $Policy = Invoke-NativeCapture 'sbx' @('policy', 'init', 'deny-all')
    if ($Policy.Code -ne 0 -and $Policy.Text -notmatch '(?i)already (?:been )?(?:initialized|configured)') {
        throw "Cannot initialize sandbox network policy: $($Policy.Text)"
    }
    Write-Host '    Ready. Per-sandbox rules and effective decisions are verified before agent startup.' -ForegroundColor Green
}
