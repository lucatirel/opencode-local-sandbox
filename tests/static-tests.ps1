$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\scripts\private\Common.ps1")

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) { throw "$Message Expected=[$Expected] Actual=[$Actual]" }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$First = Get-ProjectSandboxName -ProjectPath "C:\Projects\Alpha App" -Prefix "oc"
$FirstAgain = Get-ProjectSandboxName -ProjectPath "C:\Projects\Alpha App" -Prefix "oc"
$Second = Get-ProjectSandboxName -ProjectPath "D:\Work\Alpha App" -Prefix "oc"

Assert-Equal $First $FirstAgain "The same path must produce the same sandbox name."
Assert-True ($First -ne $Second) "Different paths with the same leaf name must produce different sandbox names."
Assert-True ($First -match '^oc-alpha-app-[0-9a-f]{8}$') "Unexpected sandbox name format: $First"

$ToolRoot = Get-ToolRoot
$FakeConfig = [pscustomobject]@{
    ToolRoot = $ToolRoot
    ModelAlias = "test-model"
    ModelDisplayName = "Test Model"
    ContextSize = 12345
    OutputTokens = 678
    LlamaPort = 9090
}

$Generated = Write-GeneratedOpenCodeConfig -Config $FakeConfig -SandboxName "oc-test-00000000"
try {
    $Json = Get-Content -LiteralPath $Generated -Raw | ConvertFrom-Json
    Assert-Equal "http://host.docker.internal:9090/v1" $Json.provider.'agentbox-llama'.options.baseURL "Incorrect OpenCode endpoint."
    Assert-Equal "agentbox-llama/test-model" $Json.model "Incorrect OpenCode model."
    Assert-Equal "allow" $Json.permission.'*' "The agent must be autonomous inside the microVM."
    $GeneratedModel = $Json.provider.'agentbox-llama'.models.PSObject.Properties["test-model"].Value
    Assert-Equal 12345 $GeneratedModel.limit.context "Incorrect context limit."
    Assert-Equal 678 $GeneratedModel.limit.output "Incorrect output limit."
}
finally {
    $GeneratedRoot = Join-Path $ToolRoot ".local\generated\oc-test-00000000"
    Remove-Item -LiteralPath $GeneratedRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$CommonSource = Get-Content -LiteralPath (Join-Path $ToolRoot "scripts\private\Common.ps1") -Raw
Assert-True ($CommonSource -match '"--sandbox"') "Network policy must be scoped to one sandbox."
Assert-True ($CommonSource -match '\*\*:80,\*\*:443') "The public-web wildcard must be restricted to ports 80/443."
Assert-True ($CommonSource -notmatch '"\*\*"\)') "Do not reintroduce a bare allow ** rule."
Assert-True ($CommonSource -match 'localhost:80') "localhost:80 must be explicitly denied."
Assert-True ($CommonSource -match 'localhost:443') "localhost:443 must be explicitly denied."
Assert-True ($CommonSource -match 'LlamaPort.+80.+443') "A guardrail for llama port 80/443 must exist."
Assert-True ($CommonSource -match 'Assert-EffectiveSandboxNetworkPolicy') "OpenCode must verify the effective network policy before launch."
Assert-True ($CommonSource -match 'sbx policy check network') "Security verification must query the effective Docker Sandbox decision."
Assert-True ($CommonSource -match 'OPENCODE_DISABLE_CLAUDE_CODE=1') "Claude Code compatibility must remain disabled in the hardened profile."
Assert-True ($CommonSource -match 'OPENCODE_DISABLE_AUTOUPDATE=1') "OpenCode auto-update must remain disabled in the hardened profile."

$HandoffSource = Get-Content -LiteralPath (Join-Path $ToolRoot "scripts\private\GitHandoff.ps1") -Raw
Assert-True ($HandoffSource -match '\bbundle create\b') "Handoff must create a Git bundle independent of the Docker remote."
Assert-True ($HandoffSource -match 'sbx cp') "The bundle must be copied out with sbx cp."
Assert-True ($HandoffSource -match 'bundle verify') "The host must verify the Git bundle before import."
Assert-True ($HandoffSource -match 'fetch --no-tags --force \$BundleHost') "Import must come from the verified local bundle."
Assert-True ($HandoffSource -match 'refs/ocbox/') "Handoff must land in passive refs/ocbox/* refs."
Assert-True ($HandoffSource -match 'core\.hooksPath=NUL') "Host Git hooks must be disabled during handoff."
Assert-True ($HandoffSource -match 'maintenance\.auto=false') "Automatic Git maintenance must be disabled during handoff."
Assert-True ($HandoffSource -match 'OCBOX_GIT_LFS_TRACKED') "Git LFS must block automatic destruction until dedicated transport exists."
Assert-True ($HandoffSource -match 'OCBOX_DIRTY_SUBMODULE') "Dirty/diverged submodules must block automatic destruction."
Assert-True ($HandoffSource -match 'OCBOX_MULTIPLE_WORKTREES') "Multiple worktrees must block automatic destruction."
Assert-True ($HandoffSource -match 'OCBOX_IGNOREDFILES') "Ignored files must block automatic destruction."

$OpenSource = Get-Content -LiteralPath (Join-Path $ToolRoot "scripts\open-project.ps1") -Raw
Assert-True ($OpenSource -match '--clone') "The hardened workflow must use clone mode."
Assert-True ($OpenSource -match '--no-share-skills') "The hardened workflow must disable shared skills."
Assert-True ($OpenSource -match 'Remove-SandboxAfterHandoff') "Sandbox destruction must happen only through verified handoff."
Assert-True ($OpenSource -match 'CallerLocation') "Open must restore the caller's directory after the session."

$BootstrapSource = Get-Content -LiteralPath (Join-Path $ToolRoot "scripts\bootstrap.ps1") -Raw
Assert-True ($BootstrapSource -notmatch 'mkcert') "mkcert must not be a dependency."
Assert-True ($BootstrapSource -match '\$ErrorActionPreference = "Continue"') "The sbx probe must tolerate informational stderr on Windows PowerShell 5.1."
Assert-True ($BootstrapSource -match 'OCBox does not build it') "Bootstrap must keep llama.cpp build management outside OCBox."

$NewSource = Get-Content -LiteralPath (Join-Path $ToolRoot "scripts\new-project.ps1") -Raw
Assert-True ($NewSource -match 'README\.md') "New projects must create a minimal tracked file."
Assert-True ($NewSource -match 'Initial commit') "New projects must create the initial commit required by clone mode."
Assert-True ($NewSource -match 'OCBox Bootstrap') "The bootstrap commit must not require a global Git identity."

$HandoffTestSource = Get-Content -LiteralPath (Join-Path $ToolRoot "scripts\handoff-test.ps1") -Raw
Assert-True ($HandoffTestSource -match '"shell"') "The Git handoff test must use the lightweight shell template."
Assert-True ($HandoffTestSource -notmatch '"opencode"') "The Git handoff gate must not depend on OpenCode/model startup."

$LauncherSource = Get-Content -LiteralPath (Join-Path $ToolRoot "sandbox.ps1") -Raw
Assert-True ($LauncherSource -match '"validate"') "The public launcher must expose a validate command."

$ValidateSource = Get-Content -LiteralPath (Join-Path $ToolRoot "scripts\validate.ps1") -Raw
Assert-True ($ValidateSource -match 'static-tests\.ps1') "validate must run dependency-free tests."
Assert-True ($ValidateSource -match 'security-test\.ps1') "validate must run host-isolation tests."
Assert-True ($ValidateSource -match 'handoff-test\.ps1') "validate must run the Git handoff test."
Assert-True ($ValidateSource -match 'OCBOX VALIDATION: PASS') "validate must provide an explicit release-gate success marker."

Write-Host "Static functional tests passed." -ForegroundColor Green
