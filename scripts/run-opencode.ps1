$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$ConfigFile = Join-Path $RepoRoot "config.local.ps1"

if (-not (Test-Path $ConfigFile)) {
    throw "config.local.ps1 is missing. Copy config.example.ps1 to config.local.ps1 and configure it."
}

. $ConfigFile

Set-Location $RepoRoot

Write-Host "Starting OpenCode sandbox: $SandboxName" -ForegroundColor Cyan
& sbx run --name $SandboxName
