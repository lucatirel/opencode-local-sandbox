[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "private\Common.ps1")

Assert-Command "git"
Assert-Command "sbx"

$Config = Get-ToolConfig
$Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$DemoRoot = Join-Path "C:\Users\Public" "OCBox-Demo-$Stamp"
$OpenScript = Join-Path $PSScriptRoot "open-project.ps1"
$StartLlamaScript = Join-Path $PSScriptRoot "start-llama.ps1"
$Prompt = "Create hello.txt with exactly this line: OCBox demo: agent wrote this inside the sandbox. Then run git status --short and stop."
$DemoServer = $null
$PreflightSandbox = "oc-demo-preflight-$([Guid]::NewGuid().ToString('N').Substring(0,8))"

function Start-DemoLlamaHidden {
    param([Parameter(Mandatory = $true)]$Config)

    if (Test-LlamaApi -Port ([int]$Config.LlamaPort)) {
        Write-Host "      PASS  llama-server already running" -ForegroundColor Green
        return $null
    }

    Write-Host "      Starting llama-server hidden before recording..." -ForegroundColor DarkGray
    $QuotedScript = '"' + $StartLlamaScript + '"'
    $Launcher = Start-Process -FilePath "powershell.exe" -ArgumentList "-ExecutionPolicy Bypass -File $QuotedScript" -WindowStyle Hidden -PassThru

    $Deadline = (Get-Date).AddSeconds([int]$Config.ServerStartupTimeoutSeconds)
    while ((Get-Date) -lt $Deadline) {
        if (Test-LlamaApi -Port ([int]$Config.LlamaPort)) {
            Write-Host "      PASS  llama-server ready" -ForegroundColor Green
            return [pscustomobject]@{
                ProcessId = $Launcher.Id
                Port      = [int]$Config.LlamaPort
            }
        }
        if ($Launcher.HasExited) {
            throw "llama-server exited before the local API became ready."
        }
        Start-Sleep -Seconds 2
    }

    Stop-LlamaProcessTree -ProcessId $Launcher.Id -Port ([int]$Config.LlamaPort)
    throw "llama-server did not become ready within $($Config.ServerStartupTimeoutSeconds) seconds."
}

function Get-LatestOcboxSnapshotRef {
    param([Parameter(Mandatory = $true)][string]$ProjectPath)

    $Refs = @(& git -C $ProjectPath for-each-ref --sort=-creatordate --format="%(refname)" "refs/ocbox/*/snapshot")
    if ($LASTEXITCODE -ne 0) { throw "Could not enumerate OCBox snapshot refs." }
    return @($Refs | ForEach-Object { "$($_)".Trim() } | Where-Object { $_ }) | Select-Object -First 1
}

Write-Host ""
Write-Host "OCBox launch demo preflight" -ForegroundColor Cyan
Write-Host "Everything slow or authentication-sensitive happens before recording." -ForegroundColor DarkGray
Write-Host ""

New-Item -ItemType Directory -Path $DemoRoot | Out-Null
"# OCBox Demo`n`nHost baseline file.`n" | Set-Content -LiteralPath (Join-Path $DemoRoot "README.md") -Encoding UTF8

& git -C $DemoRoot init -q
if ($LASTEXITCODE -ne 0) { throw "Could not initialize demo repository." }
& git -C $DemoRoot branch -M main
& git -C $DemoRoot add README.md
& git -C $DemoRoot -c user.name="OCBox Demo" -c user.email="demo@localhost" commit -q -m "Demo baseline"
if ($LASTEXITCODE -ne 0) { throw "Could not create demo baseline commit." }

$Baseline = (& git -C $DemoRoot rev-parse HEAD).Trim()

try {
    Write-Host "[1/2] Docker Sandbox preflight" -ForegroundColor Cyan
    $Previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $PreflightOut = @(& sbx create --name $PreflightSandbox --clone --no-share-skills opencode $DemoRoot 2>&1)
        $PreflightCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $Previous
    }

    if ($PreflightCode -ne 0) {
        $PreflightText = (($PreflightOut | ForEach-Object { "$($_)" }) -join "`n").Trim()
        $Hint = if ($PreflightText -match '(?i)(token|unauthor|login\.docker\.com|jwks|registry|credential|sign.?in|session)') {
            "Run 'sbx login', confirm Docker sign-in succeeds, then rerun '.\sandbox.ps1 demo'."
        }
        else {
            "Fix the Docker Sandbox error below, then rerun '.\sandbox.ps1 demo'."
        }
        throw "Docker Sandbox preflight failed BEFORE recording.`n$Hint`n`n$PreflightText"
    }
    Write-Host "      PASS  OpenCode sandbox template available" -ForegroundColor Green

    $Previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & sbx rm --force $PreflightSandbox 1>$null 2>$null
    }
    finally {
        $ErrorActionPreference = $Previous
    }

    Write-Host "[2/2] Local model preflight" -ForegroundColor Cyan
    $DemoServer = Start-DemoLlamaHidden -Config $Config

    try {
        Set-Clipboard -Value $Prompt
        Write-Host "      PASS  Prompt copied to clipboard" -ForegroundColor Green
    }
    catch {
        Write-Host "      WARNING  Could not copy prompt automatically" -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "READY." -ForegroundColor Green
    Write-Host "Maximize this terminal and start screen recording now." -ForegroundColor Green
    Write-Host "After you press ENTER, the screen will clear and the final single-take demo begins." -ForegroundColor DarkGray
    Write-Host "Keep recording until OCBOX DEMO: PASS appears." -ForegroundColor DarkGray
    Write-Host ""
    Read-Host "Press ENTER to begin" | Out-Null

    Clear-Host

    Write-Host "OCBox - autonomous OpenCode, isolated from the Windows host" -ForegroundColor Cyan
    Write-Host "==========================================================" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "1. HOST BEFORE" -ForegroundColor Cyan
    Write-Host "   Windows checkout is clean:" -ForegroundColor DarkGray
    Push-Location $DemoRoot
    try {
        Write-Host ""
        Write-Host "   PS> git status --short" -ForegroundColor White
        $BeforeStatus = @(& git status --short)
        if ($LASTEXITCODE -ne 0) { throw "git status failed before the demo." }
        if ($BeforeStatus.Count -eq 0) {
            Write-Host "   (clean)" -ForegroundColor Green
        }
        else {
            $BeforeStatus | ForEach-Object { Write-Host "   $_" }
        }
        Write-Host ""
        Write-Host "   PS> .\sandbox.ps1 open C:\Users\Public\OCBox-Demo" -ForegroundColor White
    }
    finally {
        Pop-Location
    }

    Write-Host ""
    Write-Host "2. SANDBOX" -ForegroundColor Cyan
    & $OpenScript -ProjectPath $DemoRoot -NoAutoStartServer -DemoMode
    if (-not $?) { throw "The OCBox demo session did not complete successfully." }

    Write-Host ""
    Write-Host "3. HOST AFTER" -ForegroundColor Cyan
    Write-Host "   Agent work has been exported, but the Windows checkout is still clean:" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "   PS> git status --short" -ForegroundColor White
    $AfterStatus = @(& git -C $DemoRoot status --short)
    if ($LASTEXITCODE -ne 0) { throw "git status failed after the demo." }
    if ($AfterStatus.Count -eq 0) {
        Write-Host "   (clean)" -ForegroundColor Green
    }
    else {
        $AfterStatus | ForEach-Object { Write-Host "   $_" }
    }

    $AfterHead = (& git -C $DemoRoot rev-parse HEAD).Trim()
    if ($AfterHead -ne $Baseline) {
        throw "DEMO FAIL: host HEAD changed from $Baseline to $AfterHead"
    }
    $Porcelain = ((& git -C $DemoRoot status --porcelain) -join "`n").Trim()
    if (-not [string]::IsNullOrWhiteSpace($Porcelain)) {
        throw "DEMO FAIL: host working tree changed:`n$Porcelain"
    }

    Write-Host ""
    Write-Host "   PASS  Host HEAD unchanged" -ForegroundColor Green
    Write-Host "   PASS  Host working tree clean" -ForegroundColor Green

    $Ref = Get-LatestOcboxSnapshotRef -ProjectPath $DemoRoot
    if ([string]::IsNullOrWhiteSpace($Ref)) {
        throw "DEMO FAIL: no preserved OCBox snapshot ref found."
    }

    Write-Host ""
    Write-Host "4. PRESERVED AGENT OUTPUT" -ForegroundColor Cyan
    Write-Host "   The change exists only in the passive OCBox snapshot:" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "   PS> git diff HEAD..refs/ocbox/.../snapshot -- hello.txt" -ForegroundColor White
    & git -C $DemoRoot diff --no-ext-diff --no-textconv HEAD..$Ref -- hello.txt
    if ($LASTEXITCODE -ne 0) { throw "Could not render preserved demo patch." }

    if ($null -ne $DemoServer) {
        Stop-LlamaProcessTree -ProcessId ([int]$DemoServer.ProcessId) -Port ([int]$DemoServer.Port)
        $DemoServer = $null
    }

    Write-Host ""
    Write-Host "OCBOX DEMO: PASS" -ForegroundColor Green
    Write-Host "Agent autonomy inside. Host checkout untouched outside." -ForegroundColor Green
    Write-Host "STOP RECORDING." -ForegroundColor Green
}
finally {
    $Previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & sbx rm --force $PreflightSandbox 1>$null 2>$null
    }
    finally {
        $ErrorActionPreference = $Previous
    }

    if ($null -ne $DemoServer) {
        Stop-LlamaProcessTree -ProcessId ([int]$DemoServer.ProcessId) -Port ([int]$DemoServer.Port)
    }
}
