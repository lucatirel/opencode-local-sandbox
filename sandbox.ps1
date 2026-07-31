[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet("help", "bootstrap", "doctor", "server", "new", "open")]
    [string]$Command = "help",

    [Parameter(Position = 1)]
    [string]$Target
)

$ErrorActionPreference = "Stop"
$Scripts = Join-Path $PSScriptRoot "scripts"

switch ($Command) {
    "bootstrap" {
        & (Join-Path $Scripts "bootstrap.ps1")
    }
    "doctor" {
        & (Join-Path $Scripts "doctor.ps1")
    }
    "server" {
        & (Join-Path $Scripts "start-llama.ps1")
    }
    "new" {
        if ([string]::IsNullOrWhiteSpace($Target)) {
            $Target = Read-Host "Nome del nuovo progetto"
        }
        & (Join-Path $Scripts "new-project.ps1") -Name $Target
    }
    "open" {
        if ([string]::IsNullOrWhiteSpace($Target)) {
            $Target = Read-Host "Percorso completo del progetto"
        }
        & (Join-Path $Scripts "open-project.ps1") -ProjectPath $Target
    }
    default {
        Write-Host ""
        Write-Host "OpenCode Local Sandbox" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  .\sandbox.ps1 bootstrap              prima configurazione del PC"
        Write-Host "  .\sandbox.ps1 doctor                 controlla installazione e file"
        Write-Host "  .\sandbox.ps1 server                 avvia llama-server in primo piano"
        Write-Host "  .\sandbox.ps1 new nome-progetto      crea Git + sandbox e apre OpenCode"
        Write-Host "  .\sandbox.ps1 open C:\Projects\app   apre un progetto esistente"
        Write-Host ""
    }
}

