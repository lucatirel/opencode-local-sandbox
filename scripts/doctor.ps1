[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "private\Common.ps1")

$Checks = New-Object System.Collections.Generic.List[object]

function Add-Check {
    param([string]$Name, [bool]$Ok, [string]$Detail)

    $Checks.Add([pscustomobject]@{
        Status = if ($Ok) { "OK" } else { "ERROR" }
        Check  = $Name
        Detail = $Detail
    })
}

foreach ($Command in @("git", "sbx")) {
    $Found = Get-Command $Command -ErrorAction SilentlyContinue
    Add-Check -Name "Command: $Command" -Ok ($null -ne $Found) -Detail $(if ($Found) { $Found.Source } else { "not found" })
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
    Add-Check -Name "GGUF model" -Ok (Test-Path -LiteralPath $Model -PathType Leaf) -Detail $Model
    Add-Check -Name "Hardened llama port" -Ok ([int]$Config.LlamaPort -notin @(80, 443)) -Detail "port=$($Config.LlamaPort)"
    Add-Check -Name "Clone mode" -Ok ([bool]$Config.UseCloneMode) -Detail "UseCloneMode=$($Config.UseCloneMode)"
    Add-Check -Name "Shared skills disabled" -Ok ([bool]$Config.DisableSharedSkills) -Detail "DisableSharedSkills=$($Config.DisableSharedSkills)"
    Add-Check -Name "SSH agent forwarding disabled" -Ok ([bool]$Config.DisableSshAgentForwarding) -Detail "DisableSshAgentForwarding=$($Config.DisableSshAgentForwarding)"
    Add-Check -Name "Disposable lifecycle" -Ok ([bool]$Config.DestroyWorkSandboxOnExit) -Detail "DestroyWorkSandboxOnExit=$($Config.DestroyWorkSandboxOnExit)"

    $ApiReady = Test-LlamaApi -Port ([int]$Config.LlamaPort)
    Add-Check -Name "llama.cpp API" -Ok $ApiReady -Detail $(if ($ApiReady) { "http://127.0.0.1:$($Config.LlamaPort)/v1" } else { "server is not currently running/reachable" })
}

Write-Host ""
$Checks | Format-Table -AutoSize

$Errors = @($Checks | Where-Object { $_.Status -eq "ERROR" -and $_.Check -ne "llama.cpp API" })
if ($Errors.Count -gt 0) {
    throw "Doctor: $($Errors.Count) required check(s) failed."
}

if ($Config -and -not (Test-LlamaApi -Port ([int]$Config.LlamaPort))) {
    Write-Host "Note: the llama.cpp API may be offline before a session; OCBox can start it automatically." -ForegroundColor Yellow
}
else {
    Write-Host "Doctor completed without errors." -ForegroundColor Green
}
