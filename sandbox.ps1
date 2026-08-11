[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet("help", "bootstrap", "doctor", "server", "new", "open", "review", "handoff", "security-test", "handoff-test")]
    [string]$Command = "help",

    [Parameter(Position = 1)]
    [string]$Target
)

$ErrorActionPreference = "Stop"
$Scripts = Join-Path $PSScriptRoot "scripts"

switch ($Command) {
    "bootstrap" { & (Join-Path $Scripts "bootstrap.ps1") }
    "doctor" { & (Join-Path $Scripts "doctor.ps1") }
    "server" { & (Join-Path $Scripts "start-llama.ps1") }
    "security-test" { & (Join-Path $Scripts "security-test.ps1") }
    "handoff-test" { & (Join-Path $Scripts "handoff-test.ps1") }
    "handoff" {
        if ([string]::IsNullOrWhiteSpace($Target)) { $Target = Read-Host "Percorso completo del progetto da recuperare" }
        & (Join-Path $Scripts "handoff-project.ps1") -ProjectPath $Target
    }
    "review" {
        if ([string]::IsNullOrWhiteSpace($Target)) { $Target = Read-Host "Percorso completo del progetto" }
        & (Join-Path $Scripts "review-project.ps1") -ProjectPath $Target
    }
    "new" {
        if ([string]::IsNullOrWhiteSpace($Target)) { $Target = Read-Host "Nome del nuovo progetto" }
        & (Join-Path $Scripts "new-project.ps1") -Name $Target
    }
    "open" {
        if ([string]::IsNullOrWhiteSpace($Target)) { $Target = Read-Host "Percorso completo del progetto" }
        & (Join-Path $Scripts "open-project.ps1") -ProjectPath $Target
    }
    default {
        Write-Host ""
        Write-Host "OpenCode Local Sandbox" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  .\sandbox.ps1 bootstrap               configure this PC"
        Write-Host "  .\sandbox.ps1 doctor                  validate local setup"
        Write-Host "  .\sandbox.ps1 security-test           verify host isolation"
        Write-Host "  .\sandbox.ps1 handoff-test            verify disposable Git handoff"
        Write-Host "  .\sandbox.ps1 open C:\Projects\app    run OpenCode in a disposable clone"
        Write-Host "  .\sandbox.ps1 review C:\Projects\app  inspect latest agent snapshot safely"
        Write-Host "  .\sandbox.ps1 handoff C:\Projects\app recover a sandbox after failed cleanup"
        Write-Host "  .\sandbox.ps1 new nome-progetto       create and open a new Git project"
        Write-Host "  .\sandbox.ps1 server                  run llama-server manually"
        Write-Host ""
    }
}
