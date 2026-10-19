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
    try { Assert-HardenedAgentConfig -Config $Config; Add-Check -Name 'Hardened startup configuration' -Ok $true -Detail 'required isolation flags and limits accepted' }
    catch { Add-Check -Name 'Hardened startup configuration' -Ok $false -Detail $_.Exception.Message }
    Add-Check -Name 'Server mode' -Ok ($Config.ServerMode -in @('single', 'router', 'external')) -Detail $Config.ServerMode
    if ($Config.ServerMode -ne 'external') {
        $Server = Join-Path $Config.LlamaRoot 'build\bin\Release\llama-server.exe'
        Add-Check -Name 'llama-server.exe' -Ok (Test-Path -LiteralPath $Server -PathType Leaf) -Detail $Server
        if ($Config.ServerMode -eq 'router') {
            $PresetOk = Test-Path -LiteralPath $Config.ModelsPreset -PathType Leaf
            Add-Check -Name 'Router preset' -Ok $PresetOk -Detail $Config.ModelsPreset
            if ($PresetOk) {
                $Aliases = @(Read-LlamaPresets -Path $Config.ModelsPreset | ForEach-Object { $_.Alias })
                Add-Check -Name 'Router model alias' -Ok ($Aliases -contains $Config.ModelAlias) -Detail $Config.ModelAlias
                $Selected = @(Read-LlamaPresets -Path $Config.ModelsPreset | Where-Object { $_.Alias -eq $Config.ModelAlias })
                if ($Selected.Count -eq 1) {
                    Add-Check -Name 'Declared context fits preset' -Ok ($Config.ContextSize -le $Selected[0].ContextSize) -Detail "declared=$($Config.ContextSize), preset=$($Selected[0].ContextSize)"
                }
            }
        }
        else {
            $Model = Resolve-LlamaModelPath -Config $Config
            Add-Check -Name 'GGUF model' -Ok (Test-Path -LiteralPath $Model -PathType Leaf) -Detail $Model
        }
    }
    if (Get-Command sbx -ErrorAction SilentlyContinue) {
        try { Assert-SbxSshDisabled; Add-Check -Name 'sbx SSH agent forwarding' -Ok $true -Detail 'false' }
        catch { Add-Check -Name 'sbx SSH agent forwarding' -Ok $false -Detail $_.Exception.Message }
    }
    Add-Check -Name "Hardened llama port" -Ok ([int]$Config.LlamaPort -notin @(80, 443)) -Detail "port=$($Config.LlamaPort)"
    Add-Check -Name 'Generation limits' -Ok ($Config.ContextSize -gt 1 -and $Config.OutputTokens -gt 0 -and $Config.OutputTokens -lt $Config.ContextSize) -Detail "context=$($Config.ContextSize), output=$($Config.OutputTokens)"
    Add-Check -Name "Clone mode" -Ok ([bool]$Config.UseCloneMode) -Detail "UseCloneMode=$($Config.UseCloneMode)"
    Add-Check -Name "Shared skills disabled" -Ok ([bool]$Config.DisableSharedSkills) -Detail "DisableSharedSkills=$($Config.DisableSharedSkills)"
    Add-Check -Name "SSH agent forwarding disabled" -Ok ([bool]$Config.DisableSshAgentForwarding) -Detail "DisableSshAgentForwarding=$($Config.DisableSshAgentForwarding)"
    Add-Check -Name "Disposable lifecycle" -Ok ([bool]$Config.DestroyWorkSandboxOnExit) -Detail "DestroyWorkSandboxOnExit=$($Config.DestroyWorkSandboxOnExit)"

    $ApiReady = Test-LlamaApi -Port ([int]$Config.LlamaPort)
    Add-Check -Name "llama.cpp API" -Ok $ApiReady -Detail $(if ($ApiReady) { "http://127.0.0.1:$($Config.LlamaPort)/v1" } else { "server is not currently running/reachable" })
    if ($ApiReady) {
        try { Assert-LlamaModelAvailable -Config $Config; Add-Check -Name 'Live model alias' -Ok $true -Detail $Config.ModelAlias }
        catch { Add-Check -Name 'Live model alias' -Ok $false -Detail $_.Exception.Message }
    }
}

Write-Host ""
$Checks | Format-Table -AutoSize

$Errors = @($Checks | Where-Object { $_.Status -eq "ERROR" -and $_.Check -ne "llama.cpp API" })
if ($Errors.Count -gt 0) {
    throw "Doctor: $($Errors.Count) required check(s) failed."
}

if ($Config -and -not (Test-LlamaApi -Port ([int]$Config.LlamaPort))) {
    if ($Config.ServerMode -eq 'external') { Write-Host 'Start your external router before opening a project.' -ForegroundColor Yellow }
    else { Write-Host 'The API is offline; OCBox will start the configured server/router when a project opens.' -ForegroundColor Yellow }
}
else {
    Write-Host "Doctor completed without errors." -ForegroundColor Green
}
