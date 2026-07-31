[CmdletBinding()]
param(
    [string]$ProjectPath
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "private\Common.ps1")

$Config = Get-ToolConfig
Assert-Command "sbx"

$ExpectedSandboxName = $null
if (-not [string]::IsNullOrWhiteSpace($ProjectPath)) {
    $ProjectPath = Resolve-ProjectDirectory -ProjectPath $ProjectPath
    $ExpectedSandboxName = Get-ProjectSandboxName -ProjectPath $ProjectPath -Prefix $Config.SandboxPrefix
}

$Candidates = @(Get-SandboxRecords | Where-Object {
    if ($ExpectedSandboxName) {
        $_.Name -eq $ExpectedSandboxName
    }
    else {
        $_.Name -like "$($Config.SandboxPrefix)-*"
    }
})

Write-Host ""
Write-Host "Sandbox gestite" -ForegroundColor Cyan
if ($Candidates.Count -eq 0) {
    if ($ExpectedSandboxName) {
        Write-Host "Nessuna sandbox per: $ProjectPath" -ForegroundColor Yellow
        Write-Host "Nome previsto: $ExpectedSandboxName"
    }
    else {
        Write-Host "Nessuna sandbox con prefisso '$($Config.SandboxPrefix)'." -ForegroundColor Yellow
    }
}
else {
    $Rows = foreach ($Sandbox in $Candidates) {
        $Association = "ERRORE"
        try {
            if ($ExpectedSandboxName) {
                Assert-SandboxMatchesProject -Sandbox $Sandbox -ProjectPath $ProjectPath
            }
            elseif (@($Sandbox.Workspaces).Count -eq 1) {
                $ExpectedFromWorkspace = Get-ProjectSandboxName -ProjectPath $Sandbox.Workspaces[0] -Prefix $Config.SandboxPrefix
                if ($ExpectedFromWorkspace -ne $Sandbox.Name -or $Sandbox.Agent -ine "opencode") {
                    throw "associazione non coerente"
                }
            }
            else {
                throw "numero workspace non valido"
            }
            $Association = "OK"
        }
        catch {
            $Association = "ATTENZIONE: $($_.Exception.Message)"
        }

        [pscustomobject]@{
            Sandbox = $Sandbox.Name
            Stato = $Sandbox.Status
            Agent = $Sandbox.Agent
            Workspace = (@($Sandbox.Workspaces) -join "; ")
            Associazione = $Association
        }
    }
    $Rows | Format-Table -AutoSize -Wrap
}

Write-Host ""
Write-Host "Listener llama.cpp" -ForegroundColor Cyan
$Listeners = @(Get-LlamaListenerProcesses -Port ([int]$Config.LlamaPort))
if ($Listeners.Count -eq 0) {
    Write-Host "Porta $($Config.LlamaPort) libera; nessun modello occupa la GPU per questo tool." -ForegroundColor Green
}
else {
    $Listeners | ForEach-Object {
        Write-Host "Porta $($Config.LlamaPort): $($_.ProcessName) (PID $($_.Id))" -ForegroundColor Yellow
    }
}

$LogDirectory = Join-Path $Config.ToolRoot ".local\logs"
$LastLog = @(Get-ChildItem -LiteralPath $LogDirectory -Filter "llama-*.stderr.log" -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTimeUtc -Descending |
    Select-Object -First 1)
if ($LastLog.Count -gt 0) {
    Write-Host "Ultimo log: $($LastLog[0].FullName)"
}
