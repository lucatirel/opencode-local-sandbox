function Invoke-NativeCapture {
    param([string]$FilePath, [object[]]$ArgumentList = @())
    $Previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $Lines = @(& $FilePath @ArgumentList 2>&1)
        $Code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $Previous }
    [pscustomobject]@{ Code = $Code; Text = (($Lines | ForEach-Object { "$_" }) -join "`n").Trim() }
}

function Get-SbxContentBytes {
    # This is a shared cache measurement, not the size/percentage of one image.
    if (-not $env:LOCALAPPDATA) { return 0L }
    $Store = Join-Path $env:LOCALAPPDATA 'DockerSandboxes\sandboxes\state\sandboxd\containerd\root\io.containerd.content.v1.content'
    if (-not (Test-Path -LiteralPath $Store)) { return 0L }
    $Total = Get-ChildItem -LiteralPath $Store -Recurse -File -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum
    return [long]$Total.Sum
}

function Invoke-ExternalProgress {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [object[]]$ArgumentList = @(),
        [Parameter(Mandatory = $true)][string]$Activity,
        [int]$TimeoutSeconds = 1800
    )
    $LogRoot = Join-Path (Get-ToolRoot) '.local\logs'
    New-Item -ItemType Directory -Force -Path $LogRoot | Out-Null
    $Log = Join-Path $LogRoot ("operation-{0}-{1}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'), [Guid]::NewGuid().ToString('N').Substring(0, 8))
    Write-Host "==> $Activity" -ForegroundColor Cyan
    Write-Host "    First use may download an image. Log: $Log" -ForegroundColor DarkGray
    $Watch = [Diagnostics.Stopwatch]::StartNew()
    $Baseline = Get-SbxContentBytes
    $PreviousBytes = $Baseline
    $LastSample = 0.0
    $LastReport = 0.0
    $CacheStatus = 'Preparing image / microVM'
    $ExitCode = $null
    $Tail = New-Object 'System.Collections.Generic.Queue[string]'
    $Job = Start-Job -ScriptBlock {
        param($Exe, $Arguments, $Directory)
        Set-Location -LiteralPath $Directory
        $ErrorActionPreference = 'Continue'
        & $Exe @Arguments 2>&1 | ForEach-Object { "$_" }
        [pscustomobject]@{ OcboxExitCode = $LASTEXITCODE }
    } -ArgumentList $FilePath, $ArgumentList, (Get-Location).Path
    try {
        do {
            $null = Wait-Job -Job $Job -Timeout 1
            foreach ($Item in @(Receive-Job -Job $Job -ErrorAction SilentlyContinue)) {
                if ($Item.PSObject.Properties['OcboxExitCode']) { $ExitCode = [int]$Item.OcboxExitCode; continue }
                $Line = "$Item"
                Add-Content -LiteralPath $Log -Value $Line -Encoding UTF8
                $Tail.Enqueue($Line)
                if ($Tail.Count -gt 30) { $null = $Tail.Dequeue() }
                Write-Host "    $Line"
            }
            $Seconds = $Watch.Elapsed.TotalSeconds
            if ($Seconds - $LastSample -ge 5) {
                $Bytes = Get-SbxContentBytes
                $Speed = [Math]::Max(0, ($Bytes - $PreviousBytes) / 1MB / ($Seconds - $LastSample))
                $Growth = [Math]::Max(0, ($Bytes - $Baseline) / 1MB)
                $CacheStatus = "Shared image cache +{0:n1} MiB | {1:n2} MiB/s" -f $Growth, $Speed
                $PreviousBytes = $Bytes
                $LastSample = $Seconds
            }
            # Image totals are unknown: indeterminate progress, never a fake %.
            Write-Progress -Id 21 -Activity $Activity -Status ("{0:n0}s | {1}" -f $Seconds, $CacheStatus) -PercentComplete -1
            if ($Seconds - $LastReport -ge 10) {
                Write-Host ("    {0:n0}s elapsed | {1}" -f $Seconds, $CacheStatus) -ForegroundColor DarkGray
                $LastReport = $Seconds
            }
            if ($Seconds -ge $TimeoutSeconds -and $Job.State -eq 'Running') {
                throw "Timed out after ${TimeoutSeconds}s. Inspect 'sbx ls' and $Log; an in-flight daemon operation may still finish."
            }
        } while ($Job.State -eq 'Running')
        if ($Job.State -ne 'Completed' -or $null -eq $ExitCode) {
            throw "Native worker failed: $($Job.ChildJobs[0].JobStateInfo.Reason). $($Tail.ToArray() -join "`n")"
        }
        if ($ExitCode -ne 0) {
            throw "Command failed (exit $ExitCode): $FilePath $($ArgumentList -join ' ')`n$($Tail.ToArray() -join "`n")`nLog: $Log"
        }
        Write-Host ("    PASS: {0} ({1:n1}s)" -f $Activity, $Watch.Elapsed.TotalSeconds) -ForegroundColor Green
    }
    finally {
        Write-Progress -Id 21 -Activity $Activity -Completed
        if ($Job.State -eq 'Running') { Stop-Job -Job $Job }
        Remove-Job -Job $Job -Force -ErrorAction SilentlyContinue
    }
}
