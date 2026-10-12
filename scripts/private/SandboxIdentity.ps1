Set-StrictMode -Version 3.0

function Assert-HardenedConfig {
    param([Parameter(Mandatory = $true)]$Config)
    foreach ($Name in @('UseCloneMode', 'DisableSharedSkills', 'DisableSshAgentForwarding')) {
        if ($Config.$Name -isnot [bool] -or -not $Config.$Name) {
            throw "The hardened workflow requires $Name=true. No sandbox was started."
        }
    }
}

function Get-SandboxOwnershipPath {
    param([Parameter(Mandatory = $true)][string]$SandboxName)
    if ($SandboxName -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_.+-]{0,127}$') {
        throw 'Invalid sandbox name.'
    }
    return Join-Path (Get-ToolRoot) ".local\sandboxes\$SandboxName.json"
}

function Get-SandboxRuntimeRecord {
    param([Parameter(Mandatory = $true)][string]$SandboxName)
    # Only the trusted host CLI supplies identity. Never read identity from the VM.
    $Previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $Output = @(& sbx ls --json 2>$null)
        $Code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $Previous }
    if ($Code -ne 0) { throw 'Cannot inspect sandbox identity: sbx ls --json failed.' }
    try { $Document = ($Output -join "`n") | ConvertFrom-Json -ErrorAction Stop }
    catch { throw 'Cannot inspect sandbox identity: sbx returned invalid JSON.' }
    if ($null -eq $Document) { throw 'Cannot inspect sandbox identity: empty JSON.' }
    $Items = if ($null -ne $Document.PSObject.Properties['sandboxes']) { @($Document.sandboxes) } else { @($Document) }
    $Found = @($Items | Where-Object {
        $null -ne $_ -and $null -ne $_.PSObject.Properties['name'] -and $_.name -ceq $SandboxName
    })
    if ($Found.Count -ne 1) { throw "Expected exactly one sandbox named '$SandboxName'; found $($Found.Count). Sandbox preserved." }
    $Item = $Found[0]
    foreach ($Field in @('id', 'agent', 'workspaces')) {
        if ($null -eq $Item.PSObject.Properties[$Field]) {
            throw "sbx identity schema lacks '$Field'. Refusing to infer ownership from the name. Sandbox preserved."
        }
    }
    if ($Item.id -isnot [string] -or [string]::IsNullOrWhiteSpace($Item.id) -or
        $Item.agent -isnot [string] -or [string]::IsNullOrWhiteSpace($Item.agent)) {
        throw 'Invalid sandbox identity fields. Sandbox preserved.'
    }
    $Workspaces = @($Item.workspaces)
    if ($Workspaces.Count -ne 1 -or $Workspaces[0] -isnot [string] -or
        -not [IO.Path]::IsPathRooted($Workspaces[0])) {
        throw 'Expected exactly one absolute host workspace. Sandbox preserved.'
    }
    # Some versions expose clone mode; an explicit contradictory value always fails.
    # Otherwise the host receipt attests the immutable create-time --clone flag.
    if ($null -ne $Item.PSObject.Properties['clone'] -and
        ($Item.clone -isnot [bool] -or -not $Item.clone)) {
        throw 'Runtime reports a non-clone sandbox. Sandbox preserved.'
    }
    return $Item
}

function Assert-SandboxWorkspace {
    param($Runtime, [string]$ProjectPath, [string]$Agent)
    $Expected = [IO.Path]::GetFullPath($ProjectPath).TrimEnd([char[]]@('\', '/'))
    $Actual = [IO.Path]::GetFullPath(@($Runtime.workspaces)[0]).TrimEnd([char[]]@('\', '/'))
    $Comparison = if ([IO.Path]::DirectorySeparatorChar -eq '\') { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    if (-not [string]::Equals($Expected, $Actual, $Comparison) -or $Runtime.agent -cne $Agent) {
        throw 'Sandbox agent/workspace does not match the requested project. Sandbox preserved.'
    }
}

function Register-NewSandboxOwnership {
    param(
        [Parameter(Mandatory = $true)][string]$SandboxName,
        [Parameter(Mandatory = $true)][string]$ProjectPath,
        [ValidateSet('opencode', 'shell')][string]$Agent = 'opencode',
        [ValidateSet('project', 'test')][string]$Purpose = 'project'
    )
    # Call only immediately after a successful --clone --no-share-skills create.
    # Existing/legacy sandboxes must never be automatically adopted.
    $Path = Get-SandboxOwnershipPath -SandboxName $SandboxName
    if (Test-Path -LiteralPath $Path) { throw 'An ownership receipt already exists. Refusing to overwrite it.' }
    $Runtime = Get-SandboxRuntimeRecord -SandboxName $SandboxName
    Assert-SandboxWorkspace -Runtime $Runtime -ProjectPath $ProjectPath -Agent $Agent
    $Receipt = [ordered]@{
        schemaVersion = 1
        sandboxName = $SandboxName
        sandboxId = $Runtime.id
        projectPath = [IO.Path]::GetFullPath($ProjectPath)
        agent = $Agent
        purpose = $Purpose
        clone = $true
        sharedSkillsDisabled = $true
    }
    $Directory = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    # CreateNew prevents a concurrent session from silently overwriting a receipt.
    $Bytes = [Text.Encoding]::UTF8.GetBytes(($Receipt | ConvertTo-Json))
    $Stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $Stream.Write($Bytes, 0, $Bytes.Length) }
    finally { $Stream.Dispose() }
}

function Assert-ManagedSandbox {
    param(
        [Parameter(Mandatory = $true)][string]$SandboxName,
        [Parameter(Mandatory = $true)][string]$ProjectPath,
        [ValidateSet('opencode', 'shell')][string]$Agent = 'opencode'
    )
    $Path = Get-SandboxOwnershipPath -SandboxName $SandboxName
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Sandbox '$SandboxName' has no host ownership receipt. Legacy/foreign sandbox preserved; do not recreate it before manually preserving its work."
    }
    $Receipt = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -ErrorAction Stop
    if ($Receipt.schemaVersion -ne 1 -or $Receipt.sandboxName -cne $SandboxName -or
        $Receipt.clone -isnot [bool] -or -not $Receipt.clone -or
        $Receipt.sharedSkillsDisabled -isnot [bool] -or -not $Receipt.sharedSkillsDisabled -or
        $Receipt.purpose -notin @('project', 'test')) { throw 'Invalid sandbox ownership receipt.' }
    $Runtime = Get-SandboxRuntimeRecord -SandboxName $SandboxName
    if ($Runtime.id -cne $Receipt.sandboxId -or $Receipt.agent -cne $Agent) {
        throw 'Sandbox identity changed since creation. Sandbox preserved.'
    }
    Assert-SandboxWorkspace -Runtime $Runtime -ProjectPath $ProjectPath -Agent $Agent
    Assert-SandboxWorkspace -Runtime $Runtime -ProjectPath $Receipt.projectPath -Agent $Receipt.agent
    return $Receipt
}
