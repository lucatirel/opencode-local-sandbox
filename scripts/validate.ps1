[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$ToolRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'private/Common.ps1')
$StepIndex = 0
$StepTotal = 6

function Invoke-ValidationStep {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Action
    )

    Write-Host ""
    $script:StepIndex++
    Write-Progress -Id 10 -Activity 'OCBox validation' -Status ("[{0}/{1}] {2}" -f $script:StepIndex, $script:StepTotal, $Name) -PercentComplete ([int](100 * ($script:StepIndex - 1) / $script:StepTotal))
    Write-Host ("==> [{0}/{1}] {2}" -f $script:StepIndex, $script:StepTotal, $Name) -ForegroundColor Cyan
    $Started = Get-Date
    try { & $Action }
    catch {
        Write-Progress -Id 10 -Activity 'OCBox validation' -Completed
        throw
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
    & (Join-Path $ToolRoot 'tests/startup-tests.ps1')
    & (Join-Path $ToolRoot 'tests/progress-tests.ps1')
}

# All interactive setup runs on the host. Individual long native operations
# stream their output/progress through Invoke-ExternalProgress, including stderr.
Invoke-ValidationStep 'Docker Sandbox setup' { Initialize-SbxEnvironment }
Invoke-ValidationStep 'Host isolation' { & (Join-Path $PSScriptRoot 'security-test.ps1') }
Invoke-ValidationStep 'Disposable Git handoff' { & (Join-Path $PSScriptRoot 'handoff-test.ps1') }
Write-Progress -Id 10 -Activity 'OCBox validation' -Completed

Write-Host ""
Write-Host "OCBOX VALIDATION: PASS" -ForegroundColor Green
Write-Host "Static checks, host isolation and Git handoff all passed." -ForegroundColor Green
