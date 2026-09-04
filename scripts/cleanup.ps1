[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "private\Common.ps1")

Assert-Command "sbx"

$Patterns = @(
    '^oc-security-',
    '^oc-handoff-',
    '^oc-sandbox-template-smoke-'
)

$Names = @(Get-SandboxNames)
$Candidates = @(
    $Names | Where-Object {
        $Name = $_
        @($Patterns | Where-Object { $Name -match $_ }).Count -gt 0
    } | Sort-Object -Unique
)

Write-Host ""
Write-Host "OCBox stale test sandbox cleanup" -ForegroundColor Cyan
Write-Host "Only known disposable test namespaces are eligible." -ForegroundColor DarkGray
Write-Host "Project sandboxes such as oc-<project>-<hash> and non-OCBox sandboxes are never selected." -ForegroundColor DarkGray
Write-Host ""

if ($Candidates.Count -eq 0) {
    Write-Host "Nothing to remove." -ForegroundColor Green
    return
}

Write-Host "Removing:" -ForegroundColor Yellow
$Candidates | ForEach-Object { Write-Host "  $_" }
Write-Host ""

$Failures = @()
foreach ($Sandbox in $Candidates) {
    Write-Host "Removing $Sandbox ..." -ForegroundColor Cyan
    $Old = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & sbx rm --force $Sandbox
        $Code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $Old
    }

    if ($Code -ne 0) {
        $Failures += $Sandbox
        Write-Host "FAIL: $Sandbox" -ForegroundColor Red
    }
    else {
        Write-Host "PASS: $Sandbox removed" -ForegroundColor Green
    }
}

if ($Failures.Count -gt 0) {
    throw "Cleanup failed for: $($Failures -join ', ')"
}

Write-Host ""
Write-Host "OCBOX CLEANUP: PASS ($($Candidates.Count) removed)" -ForegroundColor Green
