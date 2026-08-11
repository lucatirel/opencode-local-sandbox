[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "private\Common.ps1")

$Checks = New-Object System.Collections.Generic.List[object]
function Add-Check {
    param([string]$Name, [bool]$Ok, [string]$Detail)
    $Checks.Add([pscustomobject]@{
        Stato = if ($Ok) { "OK" } else { "ERRORE" }
        Controllo = $Name
        Dettaglio = $Detail
    })
}

foreach ($Command in @("git", "sbx")) {
    $Found = Get-Command $Command -ErrorAction SilentlyContinue
    Add-Check -Name "Comando $Command" -Ok ($null -ne $Found) -Detail $(if ($Found) { $Found.Source } else { "non trovato" })
}

$Config = $null
try {
    $Config = Get-ToolConfig
    Add-Check -Name "config.local.ps1" -Ok $true -Detail (Join-Path (Get-ToolRoot) "config.local.ps1")
}
catch {
    Add-Check -Name "config.local.ps1" -Ok $false -Detail $_.Exception.Message
}

if ($Config) {
    $Server = Join-Path $Config.LlamaRoot "build\bin\Release\llama-server.exe"
    $Model = Join-Path $Config.LlamaRoot "models\$($Config.ModelFile)"

    Add-Check -Name "llama-server.exe" -Ok (Test-Path -LiteralPath $Server -PathType Leaf) -Detail $Server
    Add-Check -Name "Modello GGUF" -Ok (Test-Path -LiteralPath $Model -PathType Leaf) -Detail $Model
    Add-Check -Name "LlamaPort hardened" -Ok ([int]$Config.LlamaPort -notin @(80, 443)) -Detail "porta=$($Config.LlamaPort)"
    Add-Check -Name "Clone mode" -Ok ([bool]$Config.UseCloneMode) -Detail "UseCloneMode=$($Config.UseCloneMode)"
    Add-Check -Name "Shared skills disabilitate" -Ok ([bool]$Config.DisableSharedSkills) -Detail "DisableSharedSkills=$($Config.DisableSharedSkills)"
    Add-Check -Name "SSH agent forwarding disabilitato" -Ok ([bool]$Config.DisableSshAgentForwarding) -Detail "DisableSshAgentForwarding=$($Config.DisableSshAgentForwarding)"
    Add-Check -Name "Disposable lifecycle" -Ok ([bool]$Config.DestroyWorkSandboxOnExit) -Detail "DestroyWorkSandboxOnExit=$($Config.DestroyWorkSandboxOnExit)"

    $ApiReady = Test-LlamaApi -Port ([int]$Config.LlamaPort)
    Add-Check -Name "API llama.cpp" -Ok $ApiReady -Detail $(if ($ApiReady) { "http://127.0.0.1:$($Config.LlamaPort)/v1" } else { "server non avviato o non raggiungibile" })
}

Write-Host ""
$Checks | Format-Table -AutoSize

$Errors = @($Checks | Where-Object { $_.Stato -eq "ERRORE" -and $_.Controllo -ne "API llama.cpp" })
if ($Errors.Count -gt 0) {
    throw "Doctor: $($Errors.Count) controllo/i richiesto/i non superato/i."
}

if ($Config -and -not (Test-LlamaApi -Port ([int]$Config.LlamaPort))) {
    Write-Host "Nota: l'API non e un errore se il server non e ancora stato avviato." -ForegroundColor Yellow
}
else {
    Write-Host "Doctor completato senza errori." -ForegroundColor Green
}
