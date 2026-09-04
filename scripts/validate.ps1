[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$ToolRoot = Split-Path -Parent $PSScriptRoot

function Invoke-ValidationStep {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Action
    )

    Write-Host ""
    Write-Host "==> $Name" -ForegroundColor Cyan
    $Started = Get-Date
    & $Action
    $Elapsed = (Get-Date) - $Started
    Write-Host ("PASS: {0} ({1:n1}s)" -f $Name, $Elapsed.TotalSeconds) -ForegroundColor Green
}

function Invoke-LongValidationScript {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$ScriptPath
    )

    Write-Host ""
    Write-Host "==> $Name" -ForegroundColor Cyan
    Write-Host "    This step creates a disposable Docker Sandbox microVM." -ForegroundColor DarkGray
    Write-Host "    Long sbx operations may be quiet; OCBox prints a heartbeat every 30s." -ForegroundColor DarkGray

    $Started = Get-Date
    $Job = Start-Job -ScriptBlock {
        param($Path, $WorkingDirectory)
        Set-Location -LiteralPath $WorkingDirectory
        & $Path
    } -ArgumentList $ScriptPath, (Get-Location).Path

    try {
        while ($Job.State -eq "Running") {
            $null = Wait-Job -Job $Job -Timeout 30
            Receive-Job -Job $Job
            if ($Job.State -eq "Running") {
                $ElapsedNow = (Get-Date) - $Started
                Write-Host ("    ...still running ({0:n0}s elapsed)" -f $ElapsedNow.TotalSeconds) -ForegroundColor DarkGray
            }
        }

        Receive-Job -Job $Job
        if ($Job.State -ne "Completed") {
            $Reason = $Job.ChildJobs[0].JobStateInfo.Reason
            if ($null -ne $Reason) { throw $Reason }
            throw "$Name failed in background job state: $($Job.State)"
        }
    }
    finally {
        Remove-Job -Job $Job -Force -ErrorAction SilentlyContinue
    }

    $Elapsed = (Get-Date) - $Started
    Write-Host ("PASS: {0} ({1:n1}s)" -f $Name, $Elapsed.TotalSeconds) -ForegroundColor Green
}

Invoke-ValidationStep "PowerShell syntax" {
    $AllErrors = @()
    Get-ChildItem -LiteralPath $ToolRoot -Recurse -Filter "*.ps1" -File |
        Where-Object { $_.FullName -notmatch '[\\/]\.local[\\/]' } |
        ForEach-Object {
            $Tokens = $null
            $Errors = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile(
                $_.FullName,
                [ref]$Tokens,
                [ref]$Errors
            )
            if ($Errors) {
                $AllErrors += $Errors | ForEach-Object {
                    "$($_.Extent.File):$($_.Extent.StartLineNumber): $($_.Message)"
                }
            }
        }

    if ($AllErrors.Count -gt 0) {
        $AllErrors | ForEach-Object { Write-Error $_ }
        throw "PowerShell parsing failed."
    }
}

Invoke-ValidationStep "Versioned JSON" {
    Get-ChildItem -LiteralPath $ToolRoot -Recurse -Filter "*.json" -File |
        Where-Object { $_.FullName -notmatch '[\\/]\.local[\\/]' } |
        ForEach-Object {
            Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json | Out-Null
        }
}

Invoke-ValidationStep "Dependency-free functional tests" {
    & (Join-Path $ToolRoot "tests\static-tests.ps1")
}

Invoke-LongValidationScript "Host isolation" (Join-Path $PSScriptRoot "security-test.ps1")
Invoke-LongValidationScript "Disposable Git handoff" (Join-Path $PSScriptRoot "handoff-test.ps1")

Write-Host ""
Write-Host "OCBOX VALIDATION: PASS" -ForegroundColor Green
Write-Host "Static checks, host isolation and Git handoff all passed." -ForegroundColor Green
