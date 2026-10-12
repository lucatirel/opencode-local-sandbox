$ErrorActionPreference = 'Stop'
$Repo = Split-Path -Parent $PSScriptRoot
$Fixture = Join-Path ([IO.Path]::GetTempPath()) ('ocbox-regression-' + [guid]::NewGuid().ToString('N'))
$Count = 0
function Check([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:Count++
}
function Must-Fail([scriptblock]$Action, [string]$Message) {
    $Failed = $false
    try { & $Action | Out-Null } catch { $Failed = $true }
    Check $Failed $Message
}
New-Item -ItemType Directory -Path $Fixture | Out-Null
Copy-Item -LiteralPath (Join-Path $Repo 'scripts') -Destination $Fixture -Recurse
. (Join-Path $Fixture 'scripts/private/Common.ps1')
. (Join-Path $Fixture 'scripts/private/GitHandoff.ps1')
$Project = Join-Path $Fixture 'security-dashboard'
New-Item -ItemType Directory -Path $Project | Out-Null
$Sandbox = 'oc-security-dashboard-12345678-clone'
$global:OcboxRegressionState = @{Runtime=[pscustomobject]@{id='runtime-1';name=$Sandbox;agent='opencode';workspaces=@($Project);clone=$true};Calls=(New-Object System.Collections.Generic.List[string]);LsCode=0;InvalidJson=$false;Removed=$false;CancelRemoval=$false}
function sbx {
    $global:OcboxRegressionState.Calls.Add(($args -join ' '))
    $global:LASTEXITCODE = 0
    if ($args[0] -eq 'ls') {
        $global:LASTEXITCODE = $global:OcboxRegressionState.LsCode
        if ($global:OcboxRegressionState.InvalidJson) { '{invalid'; return }
        if ($args -contains '-q') { if (-not $global:OcboxRegressionState.Removed) { $global:OcboxRegressionState.Runtime.name }; return }
        [pscustomobject]@{sandboxes=@($global:OcboxRegressionState.Runtime)} | ConvertTo-Json -Depth 8
    }
    if ($args[0] -eq 'rm' -and -not $global:OcboxRegressionState.CancelRemoval) { $global:OcboxRegressionState.Removed = $true }
}
try {
    $Config = [pscustomobject]@{UseCloneMode=$true;DisableSharedSkills=$true;DisableSshAgentForwarding=$true}
    Assert-HardenedConfig $Config
    foreach ($Flag in @('UseCloneMode','DisableSharedSkills','DisableSshAgentForwarding')) {
        $Config.$Flag = $false
        Must-Fail { Assert-HardenedConfig $Config } "False $Flag must be rejected."
        $Config.$Flag = $true
    }
    Must-Fail { Assert-ManagedSandbox $Sandbox $Project } 'Legacy sandbox must not be adopted.'
    Register-NewSandboxOwnership -SandboxName $Sandbox -ProjectPath $Project
    $Receipt = Assert-ManagedSandbox $Sandbox $Project
    Check ($Receipt.sandboxId -eq 'runtime-1') 'Matching identity must be accepted.'
    Must-Fail { Register-NewSandboxOwnership $Sandbox $Project } 'Receipt overwrite must fail.'

    $global:OcboxRegressionState.Runtime.id = 'replacement'
    Must-Fail { Assert-ManagedSandbox $Sandbox $Project } 'Replacement with same name must fail.'
    $global:OcboxRegressionState.Runtime.id = 'runtime-1'
    $global:OcboxRegressionState.Runtime.agent = 'shell'
    Must-Fail { Assert-ManagedSandbox $Sandbox $Project } 'Different agent must fail.'
    $global:OcboxRegressionState.Runtime.agent = 'opencode'
    $global:OcboxRegressionState.Runtime.workspaces = @($Project, $Fixture)
    Must-Fail { Assert-ManagedSandbox $Sandbox $Project } 'Extra workspace must fail.'
    $global:OcboxRegressionState.Runtime.workspaces = @($Fixture)
    Must-Fail { Assert-ManagedSandbox $Sandbox $Project } 'Wrong workspace must fail.'
    $global:OcboxRegressionState.Runtime.workspaces = @($Project)
    $global:OcboxRegressionState.Runtime.clone = $false
    Must-Fail { Assert-ManagedSandbox $Sandbox $Project } 'Direct mode must fail.'
    $global:OcboxRegressionState.Runtime.clone = $true
    $global:OcboxRegressionState.LsCode = 1
    Must-Fail { Assert-ManagedSandbox $Sandbox $Project } 'JSON with failing command must fail.'
    $global:OcboxRegressionState.LsCode = 0
    $global:OcboxRegressionState.InvalidJson = $true
    Must-Fail { Assert-ManagedSandbox $Sandbox $Project } 'Invalid JSON must fail.'
    $global:OcboxRegressionState.InvalidJson = $false
    $SavedRuntime = $global:OcboxRegressionState.Runtime
    $global:OcboxRegressionState.Runtime = [pscustomobject]@{name=$Sandbox;agent='opencode';workspaces=@($Project)}
    Must-Fail { Assert-ManagedSandbox $Sandbox $Project } 'Missing stable ID must fail.'
    $global:OcboxRegressionState.Runtime = $SavedRuntime
    Must-Fail { Get-SandboxOwnershipPath '../outside' } 'Path traversal in name must fail.'

    & (Join-Path $Fixture 'scripts/cleanup.ps1')
    Check (@($global:OcboxRegressionState.Calls | Where-Object { $_ -match '^rm ' }).Count -eq 0) 'Preview must never remove anything.'
    Must-Fail { & (Join-Path $Fixture 'scripts/cleanup.ps1') -SandboxName $Sandbox } 'Project receipt must not be eligible for cleanup.'
    Check (@($global:OcboxRegressionState.Calls | Where-Object { $_ -match '^rm ' }).Count -eq 0) 'Project cleanup must not call rm.'

    $ReceiptPath = Get-SandboxOwnershipPath $Sandbox
    $Receipt.purpose = 'test'
    $Receipt | ConvertTo-Json | Set-Content -LiteralPath $ReceiptPath -Encoding UTF8
    $global:OcboxRegressionState.Runtime.id = 'replacement'
    Must-Fail { & (Join-Path $Fixture 'scripts/cleanup.ps1') -SandboxName $Sandbox } 'Stale test receipt must not authorize deletion.'
    Check (@($global:OcboxRegressionState.Calls | Where-Object { $_ -match '^rm ' }).Count -eq 0) 'Stale cleanup must not call rm.'
    $global:OcboxRegressionState.Runtime.id = 'runtime-1'

    # Verify deletion checks the passive ref before calling sbx rm.
    & git -C $Project init -q
    & git -C $Project -c user.name=Test -c user.email=test@localhost -c core.hooksPath=NUL commit --allow-empty --no-gpg-sign -qm baseline
    if ($LASTEXITCODE -ne 0) { throw 'Git fixture initialization failed.' }
    $Sha = (& git -C $Project rev-parse HEAD).Trim()
    $Handoff = [pscustomobject]@{SandboxName=$Sandbox;ProjectPath=$Project;Agent='opencode';SessionId='test';SnapshotRef='refs/ocbox/test/snapshot';SnapshotSha=$Sha;RemoteName="sandbox-$Sandbox"}
    Must-Fail { Remove-SandboxAfterHandoff $Sandbox $Project $Handoff } 'Missing passive ref must preserve sandbox.'
    Check (@($global:OcboxRegressionState.Calls | Where-Object { $_ -match '^rm ' }).Count -eq 0) 'Invalid handoff must not call rm.'

    $global:OcboxRegressionState.CancelRemoval = $true
    Must-Fail { & (Join-Path $Fixture 'scripts/cleanup.ps1') -SandboxName $Sandbox } 'Cancelled removal must not discard the receipt.'
    Check (Test-Path -LiteralPath $ReceiptPath) 'Receipt must survive a cancelled removal.'
    $global:OcboxRegressionState.CancelRemoval = $false
    & (Join-Path $Fixture 'scripts/cleanup.ps1') -SandboxName $Sandbox
    Check ($global:OcboxRegressionState.Calls.Contains("rm $Sandbox")) 'Explicit owned test cleanup should call rm without --force.'
    Check (-not (Test-Path -LiteralPath $ReceiptPath)) 'Successful cleanup removes only its receipt.'

    # Positive control for verified handoff removal; rm remains a mock.
    $global:OcboxRegressionState.Removed = $false
    Register-NewSandboxOwnership -SandboxName $Sandbox -ProjectPath $Project
    & git -C $Project update-ref $Handoff.SnapshotRef $Sha
    if ($LASTEXITCODE -ne 0) { throw 'Cannot create passive ref fixture.' }
    $Handoff.SnapshotSha = 'f' * 40
    Must-Fail { Remove-SandboxAfterHandoff $Sandbox $Project $Handoff } 'Changed passive ref must preserve sandbox.'
    Check (-not $global:OcboxRegressionState.Removed) 'Mismatched SHA must not remove sandbox.'
    $Handoff.SnapshotSha = $Sha
    Remove-SandboxAfterHandoff $Sandbox $Project $Handoff
    Check $global:OcboxRegressionState.Removed 'Verified handoff should reach the mocked removal.'
    Check (-not (Test-Path -LiteralPath $ReceiptPath)) 'Verified removal retires the receipt.'
    Check ((& git -C $Project rev-parse $Handoff.SnapshotRef).Trim() -eq $Sha) 'Passive ref survives removal.'
    Write-Host "Security regressions: PASS ($Count checks)" -ForegroundColor Green
}
finally {
    Remove-Item -LiteralPath $Fixture -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Variable OcboxRegressionState -Scope Global -ErrorAction SilentlyContinue
    $global:LASTEXITCODE = 0
}
