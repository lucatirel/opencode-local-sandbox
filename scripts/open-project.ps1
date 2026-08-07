[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$ProjectPath,

    [string]$SandboxName,
    [switch]$NoAttach,
    [switch]$NoAutoStartServer
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "private\Common.ps1")

$Config = Get-ToolConfig
Assert-Command "sbx"
Assert-Command "mkcert"

$ProjectPath = Resolve-ProjectDirectory -ProjectPath $ProjectPath
if ([string]::IsNullOrWhiteSpace($SandboxName)) {
    $SandboxName = Get-ProjectSandboxName -ProjectPath $ProjectPath -Prefix $Config.SandboxPrefix
}

if (-not (Test-LlamaApi -Port ([int]$Config.LlamaPort))) {
    if ($NoAutoStartServer) {
        Write-Warning "llama-server non risponde. Avvialo con: .\sandbox.ps1 server"
    }
    else {
        $null = Start-LlamaWindowAndWait -Config $Config
    }
}

$Existing = @(Get-SandboxNames)
if ($Existing -notcontains $SandboxName) {
    Write-Host "Creazione sandbox $SandboxName..." -ForegroundColor Cyan
    Write-Host "La prima creazione puo richiedere qualche minuto; mostro l'output di sbx qui sotto." -ForegroundColor DarkGray

    $CreateStarted = Get-Date
    Invoke-External "sbx" @(
        "create",
        "--name", $SandboxName,
        "--memory", $Config.SandboxMemory,
        "--cpus", "$($Config.SandboxCpus)",
        "opencode",
        $ProjectPath
    )
    $Elapsed = (Get-Date) - $CreateStarted
    Write-Host ("Sandbox creata in {0:n1}s." -f $Elapsed.TotalSeconds) -ForegroundColor Green
}
else {
    Write-Host "Sandbox esistente: $SandboxName" -ForegroundColor Yellow
}

Write-Host "Aggiornamento CA, configurazione OpenCode e policy locale..." -ForegroundColor Cyan
Install-SandboxConfiguration -Config $Config -SandboxName $SandboxName

Write-Host ""
Write-Host "Progetto: $ProjectPath" -ForegroundColor Green
Write-Host "Sandbox: $SandboxName" -ForegroundColor Green
Write-Host "La sandbox vede in scrittura soltanto il workspace montato."
Write-Host ""

if (-not $NoAttach) {
    Set-Location -LiteralPath $ProjectPath
    & sbx run --name $SandboxName
    if ($LASTEXITCODE -ne 0) {
        throw "OpenCode/sbx terminato con exit code $LASTEXITCODE."
    }
}
