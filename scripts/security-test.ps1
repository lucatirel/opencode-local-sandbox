[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "private\Common.ps1")

Assert-Command "sbx"
Assert-Command "git"

function Add-Result {
    param([string]$Name, [bool]$Passed, [string]$Detail)
    $script:Results.Add([pscustomobject]@{
        Result = if ($Passed) { "PASS" } else { "FAIL" }
        Check  = $Name
        Detail = $Detail
    })
}

function Invoke-SbxCapture {
    param(
        [Parameter(Mandatory = $true)][string]$Sandbox,
       