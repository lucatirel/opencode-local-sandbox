$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../scripts/private/Common.ps1')

function Assert-Boundary {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-BoundaryFailure {
    param([scriptblock]$Action, [string]$Message)
    $Failed = $false
    try { & $Action } catch { $Failed = $true }
    Assert-Boundary $Failed $Message
}

$BoundaryConfig = [pscustomobject]@{
    UseCloneMode = $true
    DisableSharedSkills = $true
    DisableSshAgentForwarding = $true
    LlamaPort = 8080
    ContextSize = 131072
    OutputTokens = 2048
    AllowFullWeb = $false
    AdditionalNetworkHosts = @('registry.npmjs.org:443')
}

Assert-HardenedAgentConfig $BoundaryConfig
foreach ($Setting in @('UseCloneMode', 'DisableSharedSkills', 'DisableSshAgentForwarding')) {
    $BoundaryConfig.$Setting = $false
    Assert-BoundaryFailure { Assert-HardenedAgentConfig $BoundaryConfig } "Unsafe $Setting was accepted."
    $BoundaryConfig.$Setting = $true
}
foreach ($Port in @(0, 80, 443, 65534, 65536)) {
    $BoundaryConfig.LlamaPort = $Port
    Assert-BoundaryFailure { Assert-HardenedAgentConfig $BoundaryConfig } "Unsafe port $Port was accepted."
}
$BoundaryConfig.LlamaPort = 8080
$BoundaryConfig.OutputTokens = $BoundaryConfig.ContextSize
Assert-BoundaryFailure { Assert-HardenedAgentConfig $BoundaryConfig } 'Invalid generation limits were accepted.'
$BoundaryConfig.OutputTokens = 2048

try {
    $script:ExistingBoundaryNames = @()
    function Get-SandboxNames { return $script:ExistingBoundaryNames }
    Assert-FreshWorkSandbox -SandboxName 'test-work'
    $script:ExistingBoundaryNames = @('test-work')
    Assert-BoundaryFailure { Assert-FreshWorkSandbox -SandboxName 'test-work' } 'An old VM was trusted based only on its name.'

    # Exercise the actual native output parser, including ambiguous/error output.
    $script:BoundaryNativeCode = 0
    $script:BoundaryNativeText = 'Allowed by rule abc'
    function sbx {
        $global:LASTEXITCODE = $script:BoundaryNativeCode
        return $script:BoundaryNativeText
    }
    Assert-Boundary ((Get-SandboxNetworkDecision 'test' 'example.com:443').Decision -eq 'allow') 'A successful allow was not recognized.'
    $script:BoundaryNativeCode = 7
    Assert-Boundary ((Get-SandboxNetworkDecision 'test' 'example.com:443').Decision -eq 'unknown') 'Failed policy commands must not grant access.'
    $script:BoundaryNativeCode = 0
    $script:BoundaryNativeText = "Allowed`nDenied"
    Assert-Boundary ((Get-SandboxNetworkDecision 'test' 'example.com:443').Decision -eq 'unknown') 'Ambiguous output must fail closed.'
    $script:BoundaryNativeText = 'Error: previously Allowed'
    Assert-Boundary ((Get-SandboxNetworkDecision 'test' 'example.com:443').Decision -eq 'unknown') 'An error mentioning Allowed must not grant access.'
    $script:BoundaryNativeText = 'Denied by rule abc'
    $script:BoundaryNativeCode = 1
    Assert-Boundary ((Get-SandboxNetworkDecision 'test' 'example.com:443').Decision -eq 'deny') 'An explicit deny exit was not recognized.'
    Remove-Item Function:sbx
    $global:LASTEXITCODE = 0

    # Model inherited global permissions without touching sbx or host policies.
    $script:InheritedBoundaryWeb = $false
    $script:BoundaryDecisions = @{}
    function Get-SandboxNetworkDecision {
        param($SandboxName, $Target)
        $Decision = 'deny'
        if ($Target -eq 'localhost:8080' -or $Target -eq 'registry.npmjs.org:443') { $Decision = 'allow' }
        if ($script:InheritedBoundaryWeb -and $Target -eq 'example.com:443') { $Decision = 'allow' }
        $script:BoundaryDecisions[$Target] = $Decision
        return [pscustomobject]@{ Code = 0; Decision = $Decision; Text = $Decision }
    }
    Assert-EffectiveSandboxNetworkPolicy -Config $BoundaryConfig -SandboxName 'test'
    Assert-Boundary ($script:BoundaryDecisions['example.com:443'] -eq 'deny') 'Restricted mode did not probe public HTTPS denial.'
    Assert-Boundary ($script:BoundaryDecisions['registry.npmjs.org:443'] -eq 'allow') 'Explicit restricted-mode exception was lost.'
    $script:InheritedBoundaryWeb = $true
    Assert-BoundaryFailure { Assert-EffectiveSandboxNetworkPolicy -Config $BoundaryConfig -SandboxName 'test' } 'Restricted mode accepted an inherited Internet allow.'
}
finally {
    foreach ($Name in @('Get-SandboxNames', 'sbx', 'Get-SandboxNetworkDecision')) {
        Remove-Item "Function:$Name" -ErrorAction SilentlyContinue
    }
    . (Join-Path $PSScriptRoot '../scripts/private/Common.ps1')
    $global:LASTEXITCODE = 0
}

Write-Host 'Security boundary regression tests passed.' -ForegroundColor Green
