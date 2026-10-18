[CmdletBinding()]
param([switch]$ConfigureModel)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'private\Common.ps1')
Assert-Command 'git'
Initialize-SbxEnvironment
if ($ConfigureModel -and -not (Test-Path -LiteralPath (Join-Path (Get-ToolRoot) 'config.local.ps1'))) {
    Initialize-OcboxModelConfig
}
