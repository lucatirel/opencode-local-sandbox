[CmdletBinding()]
param(
    [string]$ProjectPath,
    [string]$SandboxName
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "private\Common.ps1")

$Config = Get-ToolConfig
Assert-Command "sbx"

if (-not [string]::IsNullOrWhiteSpace($ProjectPath)) {
    $ProjectPath = Resolve-ProjectDirectory -ProjectPath $ProjectPath
    if ([string]::IsNullOrWhiteSpace($SandboxName)) {
        $SandboxName = Get-ProjectSandboxName -ProjectPath $ProjectPath -Prefix $Config.SandboxPrefix
    }
}

if (-not [string]::IsNullOrWhiteSpace($SandboxName)) {
    Stop-SandboxSafely -SandboxName $SandboxName
}

Stop-LlamaListeners -Config $Config

if (Test-LlamaApi -Port ([int]$Config.LlamaPort)) {
    throw "Pulizia incompleta: la porta $($Config.LlamaPort) risulta ancora occupata."
}

Write-Host "Pulizia completata: nessun listener llama.cpp attivo." -ForegroundColor Green
