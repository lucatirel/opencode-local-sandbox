[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$ProjectPath,

    [string]$SandboxName,
    [switch]$NoAttach,
    [switch]$ReuseExistingServer
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

$ManagedServer = $null
try {
    if (-not $NoAttach) {
        if (Test-LlamaApi -Port ([int]$Config.LlamaPort)) {
            if (-not $ReuseExistingServer) {
                Assert-LlamaPortAvailable -Config $Config
            }
            Write-Warning "Riutilizzo esplicito di un listener preesistente: non verra terminato automaticamente."
        }
        else {
            $ManagedServer = Start-ManagedLlamaServer -Config $Config
        }
    }

    $Existing = @(Get-SandboxNames)
    if ($Existing -notcontains $SandboxName) {
        Write-Host "Creazione sandbox $SandboxName..." -ForegroundColor Cyan
        Invoke-External "sbx" @(
            "create",
            "--name", $SandboxName,
            "--memory", $Config.SandboxMemory,
            "--cpus", "$($Config.SandboxCpus)",
            "opencode",
            $ProjectPath
        ) | Out-Null
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
    Write-Host "Ctrl+C chiudera OpenCode, fermera la sandbox e liberera la GPU."
    Write-Host ""

    if (-not $NoAttach) {
        Set-Location -LiteralPath $ProjectPath
        & sbx run --name $SandboxName
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "OpenCode/sbx terminato con exit code $LASTEXITCODE."
        }
    }
}
finally {
    try {
        Stop-SandboxSafely -SandboxName $SandboxName
    }
    catch {
        Write-Warning $_.Exception.Message
    }
    if ($ManagedServer) {
        try {
            Stop-ManagedLlamaServer -ManagedProcess $ManagedServer.Process -Port $ManagedServer.Port
        }
        catch {
            Write-Error $_.Exception.Message
        }
    }
}
