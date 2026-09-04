[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "private\Common.ps1")

Assert-Command "git"
Assert-Command "sbx"

$Config = Get-ToolConfig
$Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$DemoRoot = Join-Path ([Environment]::GetFolderPath("Desktop")) "OCBox-Demo-$Stamp"
$OpenScript = Join-Path $PSScriptRoot "open-project.ps1"
$ReviewScript = Join-Path $PSScriptRoot "review-project.ps1"
$StartLlamaScript = Join-Path $PSScriptRoot "start-llama.ps1"
$Prompt = "Create a file named hello.txt containing exactly: OCBox demo: agent wrote this inside the sandbox. Then show git status. Do not modify README.md."
$DemoServer = $null
$PreflightSandbox = "oc-demo-preflight-$([Guid]::NewGuid().ToString('N').Substring(0,8))"

function Start-DemoLlamaHidden {
    param([Parameter(Mandatory = $true)]$Config)

    if (Test-LlamaApi -Port ([int]$Config.LlamaPort)) {
        Write-Host "      PASS: llama-server already running." -ForegroundColor Green
        return $null
    }

    Write-Host "      Starting llama-server hidden before recording..." -ForegroundColor DarkGray
    $QuotedScript = '"' + $StartLlamaScript + '"'
    $Launcher = Start-Process -FilePath "powershell.exe" -ArgumentList "-ExecutionPolicy Bypass -File $QuotedScript" -WindowStyle Hidden -PassThru

    $Deadline = (Get-Date).AddSeconds([int]$Config.ServerStartupTimeoutSeconds)
    while ((Get-Date) -lt $Deadline) {
        if (Test-LlamaApi -Port ([int]$Config.LlamaPort)) {
            Write-Host "      PASS: llama-server ready (hidden)." -ForegroundColor Green
            return [pscustomobject]@{
                ProcessId = $Launcher.Id
                Port      = [int]$Config.LlamaPort
            }
        }

        if ($Launcher.HasExited) {
            throw "llama-server launcher exited before the local API became ready."
        }
        Start-Sleep -Seconds 2
    }

    Stop-LlamaProcessTree -ProcessId $Launcher.Id -Port ([int]$Config.LlamaPort)
    throw "llama-server did not become ready within $($Config.ServerStartupTimeoutSeconds) seconds."
}

Write-Host ""
Write-Host "OCBox launch demo" -ForegroundColor Cyan
Write-Host "All slow/auth-sensitive setup runs BEFORE you start screen recording." -ForegroundColor DarkGray
Write-Host "The recorded portion stays in this terminal; llama-server runs hidden." -ForegroundColor DarkGray
Write-Host ""

New-Item -ItemType Directory -Path $DemoRoot | Out-Null
"# OCBox Demo`n`nThis file exists on the Windows host before the sandbox starts.`n" | Set-Content -LiteralPath (Join-Path $DemoRoot "README.md") -Encoding UTF8

& git -C $DemoRoot init -q
if ($LASTEXITCODE -ne 0) { throw "Could not initialize demo repository." }
& git -C $DemoRoot branch -M main
& git -C $DemoRoot add README.md
& git -C $DemoRoot -c user.name="OCBox Demo" -c user.email="demo@localhost" commit -q -m "Demo baseline"
if ($LASTEXITCODE -ne 0) { throw "Could not create demo baseline commit." }

$Baseline = (& git -C $DemoRoot rev-parse HEAD).Trim()

try {
    Write-Host "[1/3] Docker Sandbox preflight" -ForegroundColor Cyan
    Write-Host "      Verifying Docker login/registry/template access before recording..." -ForegroundColor DarkGray

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
            "Run 'sbx login', confirm the Docker sign-in succeeds, then rerun '.\sandbox.ps1 demo'. Also verify that login.docker.com is reachable."
        }
        else {
            "Fix the Docker Sandbox error below, then rerun '.\sandbox.ps1 demo'."
        }
        throw "Docker Sandbox preflight failed BEFORE recording.`n$Hint`n`n$PreflightText"
    }

    Write-Host "      PASS: opencode sandbox template can be created." -ForegroundColor Green

    $Previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & sbx rm --force $PreflightSandbox 1>$null 2>$null
    }
    finally {
        $ErrorActionPreference = $Previous
    }
    Write-Host "      PASS: preflight sandbox removed." -ForegroundColor Green

    Write-Host ""
    Write-Host "[2/3] Local model preflight" -ForegroundColor Cyan
    $DemoServer = Start-DemoLlamaHidden -Config $Config

    try {
        Set-Clipboard -Value $Prompt
        Write-Host "      PASS: demo prompt copied to clipboard." -ForegroundColor Green
    }
    catch {
        Write-Host "      WARNING: could not copy prompt automatically." -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "[3/3] READY TO RECORD" -ForegroundColor Green
    Write-Host ""
    Write-Host "DEMO REPOSITORY" -ForegroundColor Cyan
    Write-Host "  $DemoRoot"
    Write-Host ""
    Write-Host "HOST BEFORE" -ForegroundColor Cyan
    & git -C $DemoRoot status -sb
    Write-Host "  HEAD: $Baseline" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "PROMPT TO PASTE INTO OPENCODE" -ForegroundColor Cyan
    Write-Host $Prompt -ForegroundColor Yellow
    Write-Host ""
    Write-Host "START SCREEN RECORDING NOW." -ForegroundColor Green
    Write-Host "No model-loading window should appear; llama-server is already ready and hidden." -ForegroundColor DarkGray
    Write-Host "After ENTER: paste the prompt, let OpenCode finish, then exit OpenCode normally." -ForegroundColor DarkGray
    Write-Host "Keep recording until you see OCBOX DEMO: PASS." -ForegroundColor DarkGray
    Write-Host ""
    Read-Host "Press ENTER to launch the recorded portion" | Out-Null

    & $OpenScript -ProjectPath $DemoRoot -NoAutoStartServer
    if (-not $?) {
        throw "The OCBox demo session did not complete successfully."
    }

    Write-Host ""
    Write-Host "HOST AFTER" -ForegroundColor Cyan
    $AfterHead = (& git -C $DemoRoot rev-parse HEAD).Trim()
    & git -C $DemoRoot status -sb

    if ($AfterHead -ne $Baseline) {
        throw "DEMO FAIL: host HEAD changed from $Baseline to $AfterHead"
    }

    $Porcelain = ((& git -C $DemoRoot status --porcelain) -join "`n").Trim()
    if (-not [string]::IsNullOrWhiteSpace($Porcelain)) {
        throw "DEMO FAIL: host working tree changed:`n$Porcelain"
    }

    Write-Host "  PASS: host HEAD unchanged" -ForegroundColor Green
    Write-Host "  PASS: host working tree clean" -ForegroundColor Green
    Write-Host ""
    Write-Host "PRESERVED AGENT OUTPUT" -ForegroundColor Cyan
    & $ReviewScript -ProjectPath $DemoRoot

    if ($null -ne $DemoServer) {
        Stop-LlamaProcessTree -ProcessId ([int]$DemoServer.ProcessId) -Port ([int]$DemoServer.Port)
        $DemoServer = $null
    }

    Write-Host ""
    Write-Host "OCBOX DEMO: PASS" -ForegroundColor Green
    Write-Host "The agent changed the sandbox clone; the Windows host checkout stayed untouched." -ForegroundColor Green
    Write-Host "STOP SCREEN RECORDING NOW." -ForegroundColor Green
    Write-Host "Demo repository kept at: $DemoRoot" -ForegroundColor DarkGray
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
