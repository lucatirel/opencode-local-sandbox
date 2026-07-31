[CmdletBinding()]
param(
    [string]$ProjectPath = (Get-Location).Path,
    [string]$SandboxName
)

$ErrorActionPreference = "Stop"
Write-Warning "run-opencode.ps1 e mantenuto per compatibilita. Preferisci: .\sandbox.ps1 open <percorso>"
& (Join-Path $PSScriptRoot "open-project.ps1") -ProjectPath $ProjectPath -SandboxName $SandboxName

