$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../scripts/private/Common.ps1')

function Assert-Startup {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$Fixture = Join-Path ([IO.Path]::GetTempPath()) ('ocbox-startup-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $Fixture | Out-Null
$RealRoot = Get-ToolRoot
$SavedProfile = $env:USERPROFILE
try {
    $Preset = Join-Path $Fixture 'models.ini'
    @'
version = 1
[*]
c = 131072
flash-attn = on
[alpha]
model = /weights/a.gguf
[beta]
model = /weights/b.gguf
c = 32768
'@ | Set-Content -LiteralPath $Preset
    $Catalog = @(Read-LlamaPresets -Path $Preset)
    Assert-Startup ($Catalog.Count -eq 2) 'Router discovery lost a model.'
    Assert-Startup ($Catalog[0].ContextSize -eq 131072) 'Wildcard context must be inherited.'
    Assert-Startup ($Catalog[1].ContextSize -eq 32768) 'Per-model context must override wildcard.'

    $PathConfig = [pscustomobject]@{ LlamaRoot = $Fixture; ModelsDirectory = (Join-Path $Fixture 'external-weights'); ModelFile = 'model.gguf' }
    Assert-Startup ((Resolve-LlamaModelPath $PathConfig) -eq (Join-Path $Fixture 'external-weights/model.gguf')) 'External model directories must work.'
    $PathConfig.ModelFile = Join-Path $Fixture 'absolute.gguf'
    Assert-Startup ((Resolve-LlamaModelPath $PathConfig) -eq $PathConfig.ModelFile) 'Absolute GGUF paths must remain absolute.'

    # Bootstrap an actual ignored local config, then migrate it without losing tuning.
    Copy-Item (Join-Path $RealRoot 'config.example.ps1') (Join-Path $Fixture 'config.example.ps1')
    function Get-ToolRoot { return $Fixture }
    function Get-LlamaApiModels { param([int]$Port); return @('alpha', 'beta') }
    $env:USERPROFILE = $Fixture
    Initialize-OcboxModelConfig -LlamaRoot $Fixture -ServerMode router -ModelsPreset $Preset -ModelAlias alpha -ProjectsRoot (Join-Path $Fixture 'projects')
    $Configured = Get-ToolConfig
    Assert-Startup ($Configured.ServerMode -eq 'router' -and $Configured.ModelAlias -eq 'alpha') 'Router bootstrap did not configure the chosen alias.'
    Assert-Startup ($Configured.ContextSize -eq 131072) 'Bootstrap must import the configured router context.'
    Add-Content -LiteralPath (Join-Path $Fixture 'config.local.ps1') -Value '$OutputTokens = 777'
    Initialize-OcboxModelConfig -ServerMode router -ModelAlias beta
    $Configured = Get-ToolConfig
    Assert-Startup ($Configured.OutputTokens -eq 777) 'Bootstrap overwrote user tuning.'
    Assert-Startup ($Configured.ModelAlias -eq 'beta') 'Explicit alias migration was ignored.'
    Assert-Startup ($Configured.ContextSize -eq 32768) 'Switching models must clamp context to the selected preset.'
    $ConfigSource = Get-Content -LiteralPath (Join-Path $Fixture 'config.local.ps1') -Raw
    Assert-Startup (([regex]::Matches($ConfigSource, '# BEGIN OCBOX MANAGED')).Count -eq 1) 'Bootstrap must replace its managed block idempotently.'
    $JsonFile = Write-GeneratedOpenCodeConfig -Config $Configured -SandboxName 'test-router'
    $Json = Get-Content -LiteralPath $JsonFile -Raw | ConvertFrom-Json
    Assert-Startup ($Json.model -eq 'agentbox-llama/beta') 'Wrong default model in guest config.'
    Assert-Startup ($Json.provider.'agentbox-llama'.models.PSObject.Properties.Name -contains 'alpha') 'Other router aliases must remain selectable.'
    $Bytes = [IO.File]::ReadAllBytes($JsonFile)
    Assert-Startup (-not ($Bytes[0] -eq 239 -and $Bytes[1] -eq 187 -and $Bytes[2] -eq 191)) 'Guest JSON must not contain a UTF-8 BOM.'
    $Missing = $false
    try { Assert-LlamaModelAvailable ([pscustomobject]@{ LlamaPort = 8080; ModelAlias = 'absent' }) }
    catch { $Missing = $_.Exception.Message -match 'not advertised' }
    Assert-Startup $Missing 'A missing server alias must fail before the agent starts.'
    Remove-Item Function:Get-ToolRoot, Function:Get-LlamaApiModels
    . (Join-Path $RealRoot 'scripts/private/Common.ps1')

    # Model API health requires valid JSON/data, not merely an open TCP socket.
    function Invoke-RestMethod { return [pscustomobject]@{ status = 'some other server' } }
    Assert-Startup (-not (Test-LlamaApi -Port 8080)) 'An unrelated local service was accepted as llama.cpp.'
    Remove-Item Function:Invoke-RestMethod

    # Simulate sbx 0.48 startup, restart only on an SSH setting transition,
    # preserve existing global network policies, and fail on unreadable state.
    $script:Forwarding = 'true'
    $script:Stops = 0
    $script:Starts = 0
    $script:PolicyFails = $false
    $script:Override = $false
    function Install-SbxIfMissing { }
    function Start-OcboxSbxDaemon { $script:Starts++ }
    function Test-SbxDaemonPipe { return $false }
    function Invoke-NativeCapture {
        param($FilePath, $ArgumentList)
        $Command = $ArgumentList -join ' '
        switch ($Command) {
            'version' { return [pscustomobject]@{ Code = 0; Text = 'sbx version v0.48.0 test' } }
            'ls -q' { return [pscustomobject]@{ Code = 0; Text = '' } }
            'settings get ssh.agentForwardingEnabled' { return [pscustomobject]@{ Code = 0; Text = $(if ($script:Override) { 'true' } else { $script:Forwarding }) } }
            'policy init deny-all' { return [pscustomobject]@{ Code = 1; Text = $(if ($script:PolicyFails) { 'permission denied' } else { 'policy already initialized' }) } }
            default { throw "Unexpected command: $Command" }
        }
    }
    function Invoke-External {
        param($FilePath, $ArgumentList)
        switch ($ArgumentList -join ' ') {
            'settings set ssh.agentForwardingEnabled false' { $script:Forwarding = 'false' }
            'daemon stop' { $script:Stops++ }
            default { throw "Unexpected mutation: $($ArgumentList -join ' ')" }
        }
        return 0
    }
    Initialize-SbxEnvironment
    Assert-Startup ($script:Forwarding -eq 'false' -and $script:Stops -eq 1 -and $script:Starts -eq 2) 'SSH forwarding must be disabled and the daemon restarted.'
    Initialize-SbxEnvironment
    Assert-Startup ($script:Stops -eq 1) 'Ready machines must not be restarted on every command.'
    $script:PolicyFails = $true
    $Failed = $false
    try { Initialize-SbxEnvironment } catch { $Failed = $_.Exception.Message -match 'permission denied' }
    Assert-Startup $Failed 'A policy setup error must not be treated as already initialized.'
    $script:PolicyFails = $false
    $script:Override = $true
    $Failed = $false
    try { Initialize-SbxEnvironment } catch { $Failed = $_.Exception.Message -match 'not verifiably disabled' }
    Assert-Startup $Failed 'Environment overrides must not silently re-enable SSH forwarding.'
    Assert-Startup ($script:Stops -eq 1) 'An unsuccessful SSH setting must fail before restarting the daemon.'
}
finally {
    $env:USERPROFILE = $SavedProfile
    foreach ($Name in @('Get-ToolRoot', 'Get-LlamaApiModels', 'Invoke-RestMethod', 'Install-SbxIfMissing', 'Start-OcboxSbxDaemon', 'Test-SbxDaemonPipe', 'Invoke-NativeCapture', 'Invoke-External')) {
        Remove-Item "Function:$Name" -ErrorAction SilentlyContinue
    }
    . (Join-Path $RealRoot 'scripts/private/Common.ps1')
    Remove-Item -LiteralPath $Fixture -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host 'Startup and router regression tests passed.' -ForegroundColor Green
