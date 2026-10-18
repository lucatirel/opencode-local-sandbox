[CmdletBinding()]
param(
    [string]$LlamaRoot,
    [string]$ModelFile,
    [string]$ProjectsRoot,
    [string]$ModelAlias,
    [string]$ModelsPreset,
    [ValidateSet('single', 'router', 'external')][string]$ServerMode,
    [switch]$InstallMissing
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'private/Common.ps1')
Assert-Command 'git'
Initialize-SbxEnvironment
Initialize-OcboxModelConfig -LlamaRoot $LlamaRoot -ModelFile $ModelFile -ProjectsRoot $ProjectsRoot -ModelAlias $ModelAlias -ModelsPreset $ModelsPreset -ServerMode $ServerMode
& (Join-Path $PSScriptRoot 'doctor.ps1')
Write-Host 'Bootstrap complete. Run .\sandbox.ps1 validate, then .\sandbox.ps1 open <project>.' -ForegroundColor Green
