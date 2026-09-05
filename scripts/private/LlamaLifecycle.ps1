Set-StrictMode -Version 3.0

function Get-LlamaListenerProcessIds {
    param([Parameter(Mandatory = $true)][int]$Port)

    if (-not (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue)) {
        throw "Get-NetTCPConnection is unavailable; OCBox cannot safely identify the listener on port $Port."
    }

    return @(
        Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty OwningProcess -Unique |
            Where-Object { $_ -and ([int]$_ -gt 0) } |
            ForEach-Object { [int]$_ }
    )
}

function Get-LlamaListenerDescription {
    param([Parameter(Mandatory = $true)][int]$Port)

    $Descriptions = @()
    foreach ($PidValue in @(Get-LlamaListenerProcessIds -Port $Port)) {
        $Process = Get-Process -Id $PidValue -ErrorAction SilentlyContinue
        if ($null -eq $Process) {
            $Descriptions += "PID $PidValue (exited during inspection)"
            continue
        }

        $Path = $null
        try { $Path = $Process.Path } catch { $Path = $null }
        if ([string]::IsNullOrWhiteSpace($Path)) {
            $Descriptions += "PID $PidValue ($($Process.ProcessName))"
        }
        else {
            $Descriptions += "PID $PidValue ($($Process.ProcessName)) [$Path]"
        }
    }

    if ($Descriptions.Count -eq 0) { return "no TCP listener identified" }
    return ($Descriptions -join "; ")
}

function Stop-LlamaProcessTree {
    param(
        [Parameter(Mandatory = $true)][int]$ProcessId,
        [int]$Port = 8080
    )

    Write-Host "Stopping llama-server started by this session..." -ForegroundColor Cyan

    if (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue) {
        $Previous = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            & taskkill.exe /PID $ProcessId /T /F 1>$null 2>$null
            $TaskKillExitCode = $LASTEXITCODE
        }
        finally { $ErrorActionPreference = $Previous }

        if ($TaskKillExitCode -ne 0 -and (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)) {
            Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
        }
    }

    $GraceDeadline = (Get-Date).AddSeconds(2)
    while ((Get-Date) -lt $GraceDeadline) {
        if (-not (Test-LlamaApi -Port $Port)) {
            Write-Host "llama-server stopped; port $Port is free." -ForegroundColor Green
            return
        }
        Start-Sleep -Milliseconds 200
    }

    $ListenerPids = @(Get-LlamaListenerProcessIds -Port $Port)
    if ($ListenerPids.Count -eq 0) {
        throw "Port $Port still responds after shutdown, but OCBox could not identify a listening PID. Refusing to terminate an unknown process."
    }

    foreach ($ListenerPid in $ListenerPids) {
        $ListenerProcess = Get-Process -Id $ListenerPid -ErrorAction SilentlyContinue
        if ($null -eq $ListenerProcess) { continue }

        if ($ListenerProcess.ProcessName -notmatch '^llama-server$') {
            $Description = Get-LlamaListenerDescription -Port $Port
            throw "Port $Port is still owned by an unexpected process after OCBox stopped its launcher: $Description. Refusing to terminate it automatically."
        }
    }

    foreach ($ListenerPid in $ListenerPids) {
        if (Get-Process -Id $ListenerPid -ErrorAction SilentlyContinue) {
            Write-Host "  Terminating lingering llama-server PID $ListenerPid..." -ForegroundColor DarkGray
            Stop-Process -Id $ListenerPid -Force -ErrorAction Stop
        }
    }

    $Deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $Deadline) {
        if (-not (Test-LlamaApi -Port $Port)) {
            Write-Host "llama-server stopped; port $Port is free." -ForegroundColor Green
            return
        }
        Start-Sleep -Milliseconds 250
    }

    $Description = Get-LlamaListenerDescription -Port $Port
    throw "llama-server shutdown failed: port $Port is still listening after terminating the verified llama-server process. Listener: $Description"
}
