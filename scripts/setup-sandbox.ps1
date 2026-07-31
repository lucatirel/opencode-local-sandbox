[CmdletBinding()]
param(
    [string]$ProjectPath = (Get-Location).Path,
    [string]$SandboxName
)

$ErrorActionPreference = "Stop"
Write-Warning "setup-sandbox.ps1 e mantenuto per compatibilita. Preferisci open-project.ps1."
& (Join-Path $PSScriptRoot "open-project.ps1") -ProjectPath $ProjectPath -SandboxName $SandboxName -NoAttach

