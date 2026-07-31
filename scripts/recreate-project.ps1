[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$ProjectPath,

    [switch]$Force,
    [switch]$NoAttach
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "private\Common.ps1")

$Config = Get-ToolConfig
Assert-Command "sbx"

$ProjectPath = Resolve-ProjectDirectory -ProjectPath $ProjectPath
$SandboxName = Get-ProjectSandboxName -ProjectPath $ProjectPath -Prefix $Config.SandboxPrefix
$SessionLock = Enter-LlamaSessionLock -Port ([int]$Config.LlamaPort)
try {
    $Sandbox = Get-SandboxRecord -SandboxName $SandboxName

    if ($null -ne $Sandbox) {
        Assert-SandboxMatchesProject -Sandbox $Sandbox -ProjectPath $ProjectPath
        if (-not $Force) {
            Write-Host ""
            Write-Host "Verranno eliminati soltanto VM, pacchetti e sessioni persistenti di:" -ForegroundColor Yellow
            Write-Host "  $SandboxName"
            Write-Host "Il progetto host NON verra eliminato:" -ForegroundColor Green
            Write-Host "  $ProjectPath"
            $Answer = Read-Host "Scrivi RICREA per continuare"
            if ($Answer -cne "RICREA") {
                throw "Ricreazione annullata."
            }
        }

        if (@(Get-LlamaListenerProcesses -Port ([int]$Config.LlamaPort)).Count -gt 0) {
            throw "La porta $($Config.LlamaPort) e in uso. Chiudi la sessione attiva o esegui prima: .\sandbox.ps1 stop `"$ProjectPath`""
        }

        Stop-SandboxSafely -SandboxName $SandboxName
        Write-Host "Rimozione della sola sandbox $SandboxName..." -ForegroundColor Cyan
        # RICREA is already the explicit destructive confirmation. --force
        # suppresses sbx's second prompt after the sandbox has been stopped.
        Invoke-External "sbx" @("rm", "--force", $SandboxName) | Out-Null
        if ($null -ne (Get-SandboxRecord -SandboxName $SandboxName)) {
            throw "La sandbox $SandboxName risulta ancora presente dopo la rimozione."
        }
        Write-Host "Sandbox rimossa; progetto host intatto." -ForegroundColor Green
    }
    else {
        Write-Host "Nessuna sandbox precedente da rimuovere; ne verra creata una isolata." -ForegroundColor Yellow
    }
}
finally {
    Exit-LlamaSessionLock -SessionLock $SessionLock
}

& (Join-Path $PSScriptRoot "open-project.ps1") -ProjectPath $ProjectPath -NoAttach:$NoAttach
