[CmdletBinding()]
param([string]$SandboxName)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'private\Common.ps1')
Assert-Command 'sbx'

# Names are never authority to delete. No target means preview only.
if ([string]::IsNullOrWhiteSpace($SandboxName)) {
    $Directory = Join-Path (Get-ToolRoot) '.local\sandboxes'
    Write-Host 'Preview only. No sandbox will be removed.' -ForegroundColor Cyan
    if (Test-Path -LiteralPath $Directory -PathType Container) {
        foreach ($File in @(Get-ChildItem -LiteralPath $Directory -Filter '*.json' -File)) {
            try {
                $Receipt = Get-Content -LiteralPath $File.FullName -Raw | ConvertFrom-Json
                if ($Receipt.purpose -eq 'test') { Write-Host "  $($Receipt.sandboxName)" }
            }
            catch { Write-Warning "Unreadable test receipt: $($File.Name). Nothing removed." }
        }
    }
    Write-Host 'To remove one registered test sandbox: .\sandbox.ps1 cleanup NAME'
    Write-Host 'Legacy/unregistered sandboxes require manual inspection and preservation.'
    return
}

$Path = Get-SandboxOwnershipPath -SandboxName $SandboxName
if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'No host ownership receipt. Nothing removed.' }
$Receipt = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
if ($Receipt.purpose -cne 'test') { throw 'Cleanup refuses project sandboxes. Use verified handoff.' }
$null = Assert-ManagedSandbox -SandboxName $SandboxName -ProjectPath $Receipt.projectPath -Agent $Receipt.agent
# Keep sbx confirmation and its active-session protection; never pass --force.
Invoke-External 'sbx' @('rm', $SandboxName) | Out-Null
if (@(Get-SandboxNames) -contains $SandboxName) {
    throw 'Sandbox still exists (removal cancelled or incomplete). Ownership receipt retained.'
}
Remove-Item -LiteralPath $Path -Force
Write-Host "Removed registered test sandbox: $SandboxName" -ForegroundColor Green
