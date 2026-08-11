Set-StrictMode -Version 3.0

function Get-ToolRoot {
    return (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
}

function Get-ToolConfig {
    $ToolRoot = Get-ToolRoot
    $ExampleFile = Join-Path $ToolRoot "config.example.ps1"
    $LocalFile = Join-Path $ToolRoot "config.local.ps1"

    if (-not (Test-Path -LiteralPath $ExampleFile -PathType Leaf)) {
        throw "File di configurazione base non trovato: $ExampleFile"
    }
    if (-not (Test-Path -LiteralPath $LocalFile -PathType Leaf)) {
        throw "Configurazione locale mancante. Esegui: .\sandbox.ps1 bootstrap"
    }

    . $ExampleFile
    . $LocalFile

    return [pscustomobject]@{
        ToolRoot                     = $ToolRoot
        LlamaRoot                   = $LlamaRoot
        ModelFile                   = $ModelFile
        ModelAlias                  = $ModelAlias
        ModelDisplayName            = $ModelDisplayName
        ProjectsRoot                = $ProjectsRoot
        SandboxPrefix               = $SandboxPrefix
        SandboxMemory               = $SandboxMemory
        SandboxCpus                 = $SandboxCpus
        UseCloneMode                = [bool]$UseCloneMode
        AllowFullWeb                = [bool]$AllowFullWeb
        DisableSharedSkills         = [bool]$DisableSharedSkills
        DisableSshAgentForwarding   = [bool]$DisableSshAgentForwarding
        DestroyWorkSandboxOnExit    = [bool]$DestroyWorkSandboxOnExit
        LlamaPort                   = [int]$LlamaPort
        ContextSize                 = $ContextSize
        OutputTokens                = $OutputTokens
        ServerStartupTimeoutSeconds = $ServerStartupTimeoutSeconds
        LoadMode                    = $LoadMode
        CpuMoeLayers                = $CpuMoeLayers
        GpuLayers                   = $GpuLayers
        Fit                         = $Fit
        KvCacheType                 = $KvCacheType
        BatchSize                   = $BatchSize
        UBatchSize                  = $UBatchSize
        CacheRamMiB                 = $CacheRamMiB
        Parallel                    = $Parallel
        Temperature                 = $Temperature
        TopK                        = $TopK
        TopP                        = $TopP
        MinP                        = $MinP
        DisableThinking             = $DisableThinking
        AdditionalNetworkHosts      = @($AdditionalNetworkHosts)
    }
}

function Assert-Command {
    param([Parameter(Mandatory = $true)][string]$Name)

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Comando non disponibile: $Name"
    }
}

function Invoke-External {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [object[]]$ArgumentList = @(),
        [switch]$IgnoreExitCode
    )

    & $FilePath @ArgumentList
    $Code = $LASTEXITCODE
    if (-not $IgnoreExitCode -and $Code -ne 0) {
        throw "Comando fallito (exit $Code): $FilePath $($ArgumentList -join ' ')"
    }
    return $Code
}

function Resolve-ProjectDirectory {
    param([Parameter(Mandatory = $true)][string]$ProjectPath)

    if (-not (Test-Path -LiteralPath $ProjectPath -PathType Container)) {
        throw "Cartella progetto non trovata: $ProjectPath"
    }
    return (Resolve-Path -LiteralPath $ProjectPath).Path
}

function Assert-GitRepository {
    param([Parameter(Mandatory = $true)][string]$ProjectPath)

    Assert-Command "git"

    $Previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $RootOutput = @(& git -C $ProjectPath rev-parse --show-toplevel 2>$null)
        $Code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $Previous
    }

    if ($Code -ne 0 -or $RootOutput.Count -eq 0) {
        throw "Il profilo hardened usa clone mode e richiede un repository Git con almeno un commit."
    }

    $RepoRoot = (Resolve-Path -LiteralPath ("$($RootOutput[-1])".Trim())).Path
    $Requested = (Resolve-Path -LiteralPath $ProjectPath).Path
    if (-not [string]::Equals($RepoRoot.TrimEnd('\'), $Requested.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
        throw "Apri la root del repository Git, non una sottocartella. Root rilevata: $RepoRoot"
    }

    $Previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & git -C $ProjectPath rev-parse --verify HEAD 1>$null 2>$null
        $HeadCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $Previous
    }
    if ($HeadCode -ne 0) {
        throw "Clone mode richiede almeno un commit Git. Crea un commit iniziale oppure usa .\sandbox.ps1 new <nome>."
    }
}

function Get-ProjectSandboxName {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectPath,
        [Parameter(Mandatory = $true)][string]$Prefix
    )

    $FullPath = [IO.Path]::GetFullPath($ProjectPath).ToLowerInvariant()
    $Leaf = Split-Path -Leaf $FullPath
    $Slug = ($Leaf.ToLowerInvariant() -replace '[^a-z0-9.+-]', '-').Trim('-')
    if ([string]::IsNullOrWhiteSpace($Slug)) { $Slug = "project" }
    if ($Slug.Length -gt 32) { $Slug = $Slug.Substring(0, 32).TrimEnd('-') }

    $Hasher = [Security.Cryptography.SHA256]::Create()
    try {
        $Bytes = $Hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($FullPath))
    }
    finally { $Hasher.Dispose() }

    $Hash = (($Bytes[0..3] | ForEach-Object { $_.ToString("x2") }) -join "")
    return "$Prefix-$Slug-$Hash"
}

function Get-SandboxNames {
    Assert-Command "sbx"

    $PreviousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $Output = @(& sbx ls -q 2>$null)
        $SbxListExitCode = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $PreviousErrorActionPreference }

    if ($SbxListExitCode -ne 0) {
        throw "Impossibile leggere le sandbox. Prova: sbx login"
    }
    return @($Output | ForEach-Object { "$($_)".Trim() } | Where-Object { $_ })
}

function Get-PrivateNetworkDenyResources {
    return @(
        "10.0.0.0/8",
        "100.64.0.0/10",
        "172.16.0.0/12",
        "192.168.0.0/16",
        "169.254.0.0/16",
        "fc00::/7",
        "fe80::/10"
    )
}

function Get-SandboxNetworkDecision {
    param(
        [Parameter(Mandatory = $true)][string]$SandboxName,
        [Parameter(Mandatory = $true)][string]$Target
    )

    $Previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $Output = @(& sbx policy check network --sandbox $SandboxName $Target 2>&1)
        $Code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $Previous }

    $Text = (($Output | ForEach-Object { "$($_)" }) -join "`n").Trim()
    $Decision = if ($Text -match '(?i)\bAllowed\b') {
        "allow"
    }
    elseif ($Text -match '(?i)\bDenied\b') {
        "deny"
    }
    else {
        "unknown"
    }

    return [pscustomobject]@{
        Code = $Code
        Decision = $Decision
        Text = $Text
    }
}

function Assert-EffectiveSandboxNetworkPolicy {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][string]$SandboxName
    )

    # Validate the EFFECTIVE policy, not merely whether local rule creation returned
    # success. Docker organization governance can replace local policy completely.
    $Expected = [ordered]@{
        "localhost:$($Config.LlamaPort)" = "allow"
        "localhost:80" = "deny"
        "localhost:443" = "deny"
        "localhost:65534" = "deny"
        "10.0.0.1:80" = "deny"
        "172.16.0.1:80" = "deny"
        "192.168.0.1:80" = "deny"
        "169.254.169.254:80" = "deny"
    }

    if ($Config.AllowFullWeb) {
        $Expected["example.com:80"] = "allow"
        $Expected["example.com:443"] = "allow"
    }
    else {
        foreach ($Target in @($Config.AdditionalNetworkHosts | Where-Object { $_ })) {
            $Expected[$Target] = "allow"
        }
    }

    $Failures = @()
    foreach ($Target in $Expected.Keys) {
        $Result = Get-SandboxNetworkDecision -SandboxName $SandboxName -Target $Target
        if ($Result.Decision -ne $Expected[$Target]) {
            $Failures += "$Target expected=$($Expected[$Target]) actual=$($Result.Decision) [$($Result.Text)]"
        }
    }

    if ($Failures.Count -gt 0) {
        throw "Policy sandbox effettiva non conforme. OpenCode NON viene avviato. " + ($Failures -join " | ")
    }
}

function Write-GeneratedOpenCodeConfig {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][string]$SandboxName
    )

    $Models = [ordered]@{}
    $Models[$Config.ModelAlias] = [ordered]@{
        name  = $Config.ModelDisplayName
        limit = [ordered]@{
            context = [int]$Config.ContextSize
            output  = [int]$Config.OutputTokens
        }
    }

    $Document = [ordered]@{
        '$schema' = "https://opencode.ai/config.json"
        enabled_providers = @("agentbox-llama")
        provider = [ordered]@{
            "agentbox-llama" = [ordered]@{
                npm = "@ai-sdk/openai-compatible"
                name = "llama.cpp locale"
                options = [ordered]@{
                    baseURL = "http://host.docker.internal:$($Config.LlamaPort)/v1"
                    timeout = $false
                }
                models = $Models
            }
        }
        model = "agentbox-llama/$($Config.ModelAlias)"
        permission = [ordered]@{ "*" = "allow" }
        agent = [ordered]@{ title = [ordered]@{ disable = $true } }
        compaction = [ordered]@{ auto = $true; prune = $true }
        autoupdate = $false
        share = "disabled"
    }

    $Directory = Join-Path $Config.ToolRoot ".local\generated\$SandboxName"
    New-Item -ItemType Directory -Force -Path $Directory | Out-Null
    $Path = Join-Path $Directory "opencode.json"
    $Document | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path -Encoding UTF8
    return $Path
}

function Install-SandboxConfiguration {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][string]$SandboxName
    )

    Assert-Command "sbx"

    if ([int]$Config.LlamaPort -in @(80, 443)) {
        throw "LlamaPort non puo essere 80 o 443 nel profilo hardened: quelle porte localhost sono negate esplicitamente. Usa ad esempio 8080."
    }

    Invoke-External "sbx" @("policy", "allow", "network", "--sandbox", $SandboxName, "localhost:$($Config.LlamaPort)") | Out-Null

    if ($Config.AllowFullWeb) {
        Invoke-External "sbx" @("policy", "allow", "network", "--sandbox", $SandboxName, "**:80,**:443") | Out-Null
    }
    elseif ($Config.AdditionalNetworkHosts.Count -gt 0) {
        $AllowedHosts = @($Config.AdditionalNetworkHosts | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
        if ($AllowedHosts.Count -gt 0) {
            Invoke-External "sbx" @("policy", "allow", "network", "--sandbox", $SandboxName, ($AllowedHosts -join ",")) | Out-Null
        }
    }

    $NetworkDeny = @((Get-PrivateNetworkDenyResources) + @("localhost:80", "localhost:443"))
    Invoke-External "sbx" @("policy", "deny", "network", "--sandbox", $SandboxName, ($NetworkDeny -join ",")) | Out-Null

    # Fail closed before starting the agent if the effective policy differs from
    # the threat model (including when org governance overrides local rules).
    Assert-EffectiveSandboxNetworkPolicy -Config $Config -SandboxName $SandboxName

    $GeneratedConfig = Write-GeneratedOpenCodeConfig -Config $Config -SandboxName $SandboxName

    Invoke-External "sbx" @("exec", $SandboxName, "true") | Out-Null
    Invoke-External "sbx" @("cp", $GeneratedConfig, "${SandboxName}:/tmp/opencode-local.json") | Out-Null
    Invoke-External "sbx" @("exec", $SandboxName, "sudo", "mkdir", "-p", "/etc/opencode") | Out-Null
    Invoke-External "sbx" @("exec", $SandboxName, "sudo", "install", "-m", "0644", "/tmp/opencode-local.json", "/etc/opencode/opencode.json") | Out-Null

    # OpenCode supports Claude Code compatibility by default. Disable it so a host
    # or project .claude instruction/skills tree cannot silently extend the agent
    # behavior outside the explicit project/OpenCode configuration model.
    $PersistentEnv = @"
set -eu
FILE=/etc/sandbox-persistent.sh
for LINE in 'export OPENCODE_DISABLE_CLAUDE_CODE=1' 'export OPENCODE_DISABLE_AUTOUPDATE=1'; do
  grep -qxF "`$LINE" "`$FILE" 2>/dev/null || printf '%s\n' "`$LINE" | sudo tee -a "`$FILE" >/dev/null
done
"@
    $PersistentEnv = $PersistentEnv.Replace("`r`n", "`n").Replace("`r", "")
    Invoke-External "sbx" @("exec", $SandboxName, "bash", "-lc", $PersistentEnv) | Out-Null
}

function Test-LlamaApi {
    param([Parameter(Mandatory = $true)][int]$Port)

    $Client = New-Object System.Net.Sockets.TcpClient
    try {
        $Connect = $Client.BeginConnect("127.0.0.1", $Port, $null, $null)
        if (-not $Connect.AsyncWaitHandle.WaitOne(3000, $false)) { return $false }
        $Client.EndConnect($Connect)
        return $Client.Connected
    }
    catch { return $false }
    finally { $Client.Dispose() }
}

function Stop-LlamaProcessTree {
    param(
        [Parameter(Mandatory = $true)][int]$ProcessId,
        [int]$Port = 8080
    )

    if (-not (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)) { return }

    Write-Host "Arresto llama-server avviato da questa sessione..." -ForegroundColor Cyan

    $PreviousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & taskkill.exe /PID $ProcessId /T /F 1>$null 2>$null
        $TaskKillExitCode = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $PreviousErrorActionPreference }

    if ($TaskKillExitCode -ne 0 -and (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)) {
        Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
    }

    $Deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $Deadline) {
        if (-not (Test-LlamaApi -Port $Port)) {
            Write-Host "llama-server arrestato." -ForegroundColor Green
            return
        }
        Start-Sleep -Milliseconds 250
    }

    Write-Warning "Il processo launcher e stato terminato, ma la porta $Port risponde ancora."
}

function Start-LlamaWindowAndWait {
    param([Parameter(Mandatory = $true)]$Config)

    $Script = Join-Path $Config.ToolRoot "scripts\start-llama.ps1"
    $QuotedScript = '"' + $Script + '"'
    $Launcher = Start-Process -FilePath "powershell.exe" -ArgumentList "-NoExit -ExecutionPolicy Bypass -File $QuotedScript" -PassThru

    $Deadline = (Get-Date).AddSeconds([int]$Config.ServerStartupTimeoutSeconds)
    Write-Host "Attendo che llama-server carichi il modello..." -ForegroundColor Cyan
    while ((Get-Date) -lt $Deadline) {
        if (Test-LlamaApi -Port ([int]$Config.LlamaPort)) {
            Write-Host "llama-server pronto." -ForegroundColor Green
            return [pscustomobject]@{
                ProcessId = $Launcher.Id
                Port      = [int]$Config.LlamaPort
            }
        }
        Start-Sleep -Seconds 2
    }

    Stop-LlamaProcessTree -ProcessId $Launcher.Id -Port ([int]$Config.LlamaPort)
    throw "llama-server non ha risposto entro $($Config.ServerStartupTimeoutSeconds) secondi."
}
