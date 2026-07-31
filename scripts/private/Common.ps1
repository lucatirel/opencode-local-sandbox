Set-StrictMode -Version 3.0

function Get-ToolRoot {
    return (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
}

function Get-NormalizedNetworkHosts {
    param(
        [object[]]$Hosts = @(),
        [bool]$AllowUnrestricted = $false
    )

    $Seen = @{}
    $Result = New-Object System.Collections.Generic.List[string]
    foreach ($Item in @($Hosts)) {
        if ($null -eq $Item) {
            continue
        }

        $HostName = "$Item".Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($HostName)) {
            continue
        }
        if ($HostName -eq "**" -and -not $AllowUnrestricted) {
            throw "AdditionalNetworkHosts contiene '**'. Imposta AllowUnrestrictedNetwork = `$true soltanto se vuoi davvero rete senza limiti."
        }
        if ($HostName -match '://|[\s,/\\]') {
            throw "Host di rete non valido: $HostName. Usa host o host:porta, senza schema, path, spazi o virgole."
        }
        if (-not $Seen.ContainsKey($HostName)) {
            $Seen[$HostName] = $true
            $Result.Add($HostName)
        }
    }
    return @($Result)
}

function Assert-ToolConfig {
    param([Parameter(Mandatory = $true)]$Config)

    foreach ($Property in @("LlamaRoot", "ModelFile", "ModelAlias", "ModelDisplayName", "ProjectsRoot", "SandboxPrefix", "SandboxMemory", "GpuLayers", "KvCacheType", "ReasoningFormat", "OpenCodePermission")) {
        if ([string]::IsNullOrWhiteSpace("$($Config.$Property)")) {
            throw "Configurazione non valida: $Property non puo essere vuoto."
        }
    }

    if ($Config.ModelAlias -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$') {
        throw "ModelAlias non valido: $($Config.ModelAlias)"
    }
    if ($Config.SandboxPrefix -notmatch '^[a-z0-9][a-z0-9-]{0,15}$') {
        throw "SandboxPrefix non valido: usa da 1 a 16 caratteri minuscoli, numeri o trattini."
    }
    if ($Config.SandboxMemory -notmatch '^[1-9][0-9]*(?:[kKmMgGtT](?:[iI]?[bB])?)?$') {
        throw "SandboxMemory non valido: $($Config.SandboxMemory). Esempio: 6g"
    }

    $Ranges = @(
        @("SandboxCpus", [int]$Config.SandboxCpus, 1, 256),
        @("LlamaPort", [int]$Config.LlamaPort, 1, 65535),
        @("ContextSize", [int]$Config.ContextSize, 512, 1048576),
        @("OutputTokens", [int]$Config.OutputTokens, 1, 1048576),
        @("ServerStartupTimeoutSeconds", [int]$Config.ServerStartupTimeoutSeconds, 5, 3600),
        @("TopK", [int]$Config.TopK, 0, 100000),
        @("LogRetentionCount", [int]$Config.LogRetentionCount, 1, 1000)
    )
    foreach ($Range in $Ranges) {
        if ($Range[1] -lt $Range[2] -or $Range[1] -gt $Range[3]) {
            throw "Configurazione non valida: $($Range[0]) deve essere tra $($Range[2]) e $($Range[3])."
        }
    }
    if ([int]$Config.OutputTokens -gt [int]$Config.ContextSize) {
        throw "OutputTokens non puo superare ContextSize."
    }
    if ([double]$Config.Temperature -lt 0 -or [double]$Config.Temperature -gt 5) {
        throw "Temperature deve essere tra 0 e 5."
    }
    foreach ($ProbabilityName in @("TopP", "MinP")) {
        $Probability = [double]$Config.$ProbabilityName
        if ($Probability -lt 0 -or $Probability -gt 1) {
            throw "$ProbabilityName deve essere tra 0 e 1."
        }
    }
    if ($Config.DisableThinking -isnot [bool]) {
        throw "DisableThinking deve essere `$true oppure `$false."
    }
    if ($Config.DisableSharedSkills -isnot [bool]) {
        throw "DisableSharedSkills deve essere `$true oppure `$false."
    }
    if ($Config.AllowUnrestrictedNetwork -isnot [bool]) {
        throw "AllowUnrestrictedNetwork deve essere `$true oppure `$false."
    }

    $null = Get-NormalizedNetworkHosts -Hosts @($Config.AdditionalNetworkHosts) -AllowUnrestricted ([bool]$Config.AllowUnrestrictedNetwork)
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

    # Loading defaults before local values keeps old, shorter config.local.ps1 files compatible.
    . $ExampleFile
    . $LocalFile

    $Config = [pscustomobject]@{
        ToolRoot                   = $ToolRoot
        LlamaRoot                 = $LlamaRoot
        ModelFile                 = $ModelFile
        ModelAlias                = $ModelAlias
        ModelDisplayName          = $ModelDisplayName
        ProjectsRoot              = $ProjectsRoot
        SandboxPrefix             = $SandboxPrefix
        SandboxMemory             = $SandboxMemory
        SandboxCpus               = $SandboxCpus
        LlamaPort                 = $LlamaPort
        ContextSize               = $ContextSize
        OutputTokens              = $OutputTokens
        ServerStartupTimeoutSeconds = $ServerStartupTimeoutSeconds
        GpuLayers                 = $GpuLayers
        KvCacheType               = $KvCacheType
        Temperature               = $Temperature
        TopK                      = $TopK
        TopP                      = $TopP
        MinP                      = $MinP
        ReasoningFormat           = $ReasoningFormat
        DisableThinking           = $DisableThinking
        DisableSharedSkills       = $DisableSharedSkills
        AllowUnrestrictedNetwork  = $AllowUnrestrictedNetwork
        LogRetentionCount         = $LogRetentionCount
        OpenCodePermission        = $OpenCodePermission
        AdditionalNetworkHosts    = @(Get-NormalizedNetworkHosts -Hosts @($AdditionalNetworkHosts) -AllowUnrestricted ([bool]$AllowUnrestrictedNetwork))
    }
    Assert-ToolConfig -Config $Config
    return $Config
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

    # Windows PowerShell 5.1 converts native stderr into error records. Keep
    # informational stderr visible, but decide success from the native exit code.
    $PreviousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & $FilePath @ArgumentList
        $Code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $PreviousErrorActionPreference
    }
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

function Get-ProjectSandboxName {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectPath,
        [Parameter(Mandatory = $true)][string]$Prefix
    )

    $FullPath = [IO.Path]::GetFullPath($ProjectPath).ToLowerInvariant()
    $Leaf = Split-Path -Leaf $FullPath
    $Slug = ($Leaf.ToLowerInvariant() -replace '[^a-z0-9.+-]', '-').Trim('-')
    if ([string]::IsNullOrWhiteSpace($Slug)) {
        $Slug = "project"
    }
    if ($Slug.Length -gt 32) {
        $Slug = $Slug.Substring(0, 32).TrimEnd('-')
    }

    $Hasher = [Security.Cryptography.SHA256]::Create()
    try {
        $Bytes = $Hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($FullPath))
    }
    finally {
        $Hasher.Dispose()
    }
    $Hash = (($Bytes[0..3] | ForEach-Object { $_.ToString("x2") }) -join "")
    return "$Prefix-$Slug-$Hash"
}

function Invoke-SbxCapture {
    param(
        [Parameter(Mandatory = $true)][object[]]$ArgumentList,
        [switch]$IgnoreExitCode
    )

    Assert-Command "sbx"
    $PreviousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $Output = @(& sbx @ArgumentList 2>$null)
        $ExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $PreviousErrorActionPreference
    }
    if (-not $IgnoreExitCode -and $ExitCode -ne 0) {
        throw "Comando sbx fallito (exit $ExitCode): sbx $($ArgumentList -join ' ')"
    }
    return [pscustomobject]@{
        Output = @($Output | ForEach-Object { "$($_)" })
        ExitCode = $ExitCode
    }
}

function ConvertFrom-JsonCommandOutput {
    param([Parameter(Mandatory = $true)][object[]]$Output)

    $Lines = @($Output | ForEach-Object { "$($_)" })
    $StartIndex = -1
    for ($Index = 0; $Index -lt $Lines.Count; $Index++) {
        $Trimmed = $Lines[$Index].TrimStart()
        if ($Trimmed.StartsWith("{") -or $Trimmed.StartsWith("[")) {
            $StartIndex = $Index
            break
        }
    }
    if ($StartIndex -lt 0) {
        throw "Il comando non ha restituito JSON valido."
    }

    $JsonText = ($Lines[$StartIndex..($Lines.Count - 1)] -join [Environment]::NewLine)
    try {
        $Document = $JsonText | ConvertFrom-Json
    }
    catch {
        throw "JSON non valido restituito dal comando: $($_.Exception.Message)"
    }
    Write-Output -NoEnumerate $Document
}

function Get-ObjectPropertyValue {
    param(
        [Parameter(Mandatory = $true)]$InputObject,
        [Parameter(Mandatory = $true)][string[]]$Names
    )

    foreach ($Name in $Names) {
        $Property = $InputObject.PSObject.Properties[$Name]
        if ($null -ne $Property) {
            return $Property.Value
        }
    }
    return $null
}

function Get-SandboxRecords {
    $Result = Invoke-SbxCapture -ArgumentList @("ls", "--json")
    $Document = ConvertFrom-JsonCommandOutput -Output @($Result.Output)
    $SandboxesProperty = $Document.PSObject.Properties["sandboxes"]
    $Items = if ($null -ne $SandboxesProperty) { @($SandboxesProperty.Value) } else { @($Document) }

    $Records = foreach ($Item in $Items) {
        if ($null -eq $Item) {
            continue
        }
        $Name = Get-ObjectPropertyValue -InputObject $Item -Names @("name", "Name")
        if ([string]::IsNullOrWhiteSpace("$Name")) {
            continue
        }

        $RawWorkspaces = Get-ObjectPropertyValue -InputObject $Item -Names @("workspaces", "workspace", "Workspaces", "Workspace")
        $Workspaces = foreach ($Workspace in @($RawWorkspaces)) {
            if ($null -eq $Workspace) {
                continue
            }
            if ($Workspace -is [string]) {
                "$Workspace"
                continue
            }
            $Path = Get-ObjectPropertyValue -InputObject $Workspace -Names @("path", "Path", "source", "Source")
            if (-not [string]::IsNullOrWhiteSpace("$Path")) {
                "$Path"
            }
        }

        [pscustomobject]@{
            Name = "$Name"
            Agent = "$(Get-ObjectPropertyValue -InputObject $Item -Names @('agent', 'Agent'))"
            Status = "$(Get-ObjectPropertyValue -InputObject $Item -Names @('status', 'Status'))"
            Workspaces = @($Workspaces)
        }
    }
    return @($Records)
}

function Get-SandboxNames {
    return @(Get-SandboxRecords | ForEach-Object { $_.Name })
}

function Get-SandboxRecord {
    param([Parameter(Mandatory = $true)][string]$SandboxName)

    $Matches = @(Get-SandboxRecords | Where-Object { $_.Name -eq $SandboxName } | Select-Object -First 1)
    if ($Matches.Count -eq 0) {
        return $null
    }
    return $Matches[0]
}

function Get-NormalizedProjectPath {
    param([Parameter(Mandatory = $true)][string]$ProjectPath)

    $FullPath = [IO.Path]::GetFullPath($ProjectPath)
    return $FullPath.TrimEnd([char[]]@('\', '/')).ToLowerInvariant()
}

function Assert-SandboxMatchesProject {
    param(
        [Parameter(Mandatory = $true)]$Sandbox,
        [Parameter(Mandatory = $true)][string]$ProjectPath
    )

    if ($Sandbox.Agent -ine "opencode") {
        throw "La sandbox '$($Sandbox.Name)' usa l'agent '$($Sandbox.Agent)', non OpenCode. Scegli un altro nome o ricreala esplicitamente."
    }
    if (@($Sandbox.Workspaces).Count -ne 1) {
        throw "La sandbox '$($Sandbox.Name)' deve avere esattamente un workspace host; ne risultano $(@($Sandbox.Workspaces).Count)."
    }

    $Expected = Get-NormalizedProjectPath -ProjectPath $ProjectPath
    $Actual = Get-NormalizedProjectPath -ProjectPath $Sandbox.Workspaces[0]
    if ($Expected -ine $Actual) {
        throw "La sandbox '$($Sandbox.Name)' appartiene a '$($Sandbox.Workspaces[0])', non a '$ProjectPath'. Riutilizzo bloccato."
    }
}

function ConvertTo-SbxVersion {
    param([Parameter(Mandatory = $true)][object[]]$Output)

    $VersionText = (@($Output) | ForEach-Object { "$($_)" }) -join " "
    if ($VersionText -notmatch '(?i)(?:^|\s)v?(?<Version>[0-9]+\.[0-9]+\.[0-9]+)(?:\s|$)') {
        throw "Versione sbx non riconosciuta: $VersionText"
    }
    return [Version]$Matches.Version
}

function Test-SbxSupportsNoSharedSkills {
    # sbx 0.37.0 accepts this flag but does not list it in `sbx create --help`.
    # Probe the parser first; --help prevents sandbox creation. Keep the
    # documented minimum version as a fallback for CLI builds with hidden flags.
    $ParserProbe = Invoke-SbxCapture `
        -ArgumentList @("create", "--no-share-skills", "--help") `
        -IgnoreExitCode
    if ($ParserProbe.ExitCode -eq 0) {
        return $true
    }

    try {
        $VersionResult = Invoke-SbxCapture -ArgumentList @("version")
        return ((ConvertTo-SbxVersion -Output $VersionResult.Output) -ge [Version]"0.37.0")
    }
    catch {
        return $false
    }
}

function Get-SandboxCreateArguments {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][string]$SandboxName,
        [Parameter(Mandatory = $true)][string]$ProjectPath
    )

    $Arguments = @("create")
    if ($Config.DisableSharedSkills) {
        $Arguments += "--no-share-skills"
    }
    $Arguments += @(
        "--name", $SandboxName,
        "--memory", $Config.SandboxMemory,
        "--cpus", "$($Config.SandboxCpus)",
        "opencode", $ProjectPath
    )
    return $Arguments
}

function New-ProjectSandbox {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][string]$SandboxName,
        [Parameter(Mandatory = $true)][string]$ProjectPath
    )

    if ($Config.DisableSharedSkills -and -not (Test-SbxSupportsNoSharedSkills)) {
        throw "Questa versione di sbx non supporta --no-share-skills. Aggiornala con: winget upgrade Docker.sbx"
    }
    Write-Host "Creazione sandbox isolata $SandboxName..." -ForegroundColor Cyan
    $Arguments = @(Get-SandboxCreateArguments -Config $Config -SandboxName $SandboxName -ProjectPath $ProjectPath)
    Invoke-External "sbx" $Arguments | Out-Null

    $Sandbox = Get-SandboxRecord -SandboxName $SandboxName
    if ($null -eq $Sandbox) {
        throw "La sandbox $SandboxName non risulta presente dopo la creazione."
    }
    Assert-SandboxMatchesProject -Sandbox $Sandbox -ProjectPath $ProjectPath
    return $Sandbox
}

function Enter-LlamaSessionLock {
    param([Parameter(Mandatory = $true)][int]$Port)

    $MutexName = "Local\OpenCodeLocalSandbox-Llama-Port-$Port"
    $Mutex = New-Object System.Threading.Mutex -ArgumentList $false, $MutexName
    $Acquired = $false
    try {
        $Acquired = $Mutex.WaitOne(0)
    }
    catch [System.Threading.AbandonedMutexException] {
        $Acquired = $true
    }

    if (-not $Acquired) {
        $Mutex.Dispose()
        throw "Un'altra sessione OpenCode Local Sandbox sta gia usando la porta $Port. Chiudila oppure esegui .\sandbox.ps1 status."
    }
    return [pscustomobject]@{
        Mutex = $Mutex
        Name = $MutexName
        Port = $Port
    }
}

function Exit-LlamaSessionLock {
    param($SessionLock)

    if ($null -eq $SessionLock) {
        return
    }
    try {
        $SessionLock.Mutex.ReleaseMutex()
    }
    finally {
        $SessionLock.Mutex.Dispose()
    }
}

function Test-LlamaSessionLockAvailable {
    param([Parameter(Mandatory = $true)][int]$Port)

    $Probe = $null
    try {
        $Probe = Enter-LlamaSessionLock -Port $Port
        return $true
    }
    catch {
        return $false
    }
    finally {
        if ($null -ne $Probe) {
            Exit-LlamaSessionLock -SessionLock $Probe
        }
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
                    baseURL = "https://host.docker.internal:$($Config.LlamaPort)/v1"
                    timeout = $false
                }
                models = $Models
            }
        }
        model = "agentbox-llama/$($Config.ModelAlias)"
        small_model = "agentbox-llama/$($Config.ModelAlias)"
        agent = [ordered]@{
            build = [ordered]@{ temperature = [double]$Config.Temperature }
        }
        compaction = [ordered]@{ auto = $true; prune = $true }
        permission = $Config.OpenCodePermission
        autoupdate = $false
        share = "disabled"
    }

    $Directory = Join-Path $Config.ToolRoot ".local\generated\$SandboxName"
    New-Item -ItemType Directory -Force -Path $Directory | Out-Null
    $Path = Join-Path $Directory "opencode.json"
    $Document | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path -Encoding UTF8
    return $Path
}

function Get-SandboxToolMetadata {
    param([Parameter(Mandatory = $true)][string]$SandboxName)

    $Command = 'if test -f /etc/agentbox/opencode-local-sandbox.json; then cat /etc/agentbox/opencode-local-sandbox.json; fi'
    $Result = Invoke-SbxCapture -ArgumentList @("exec", $SandboxName, "sh", "-lc", $Command) -IgnoreExitCode
    if ($Result.ExitCode -ne 0 -or $Result.Output.Count -eq 0) {
        return $null
    }
    try {
        return (ConvertFrom-JsonCommandOutput -Output @($Result.Output))
    }
    catch {
        Write-Warning "Metadati non leggibili nella sandbox ${SandboxName}: $($_.Exception.Message)"
        return $null
    }
}

function Write-GeneratedSandboxMetadata {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][string]$SandboxName,
        [Parameter(Mandatory = $true)][string]$ProjectPath,
        [Parameter(Mandatory = $true)][string]$SharedSkillsState,
        [Parameter(Mandatory = $true)][string[]]$ManagedNetworkHosts,
        $PreviousMetadata
    )

    $CreatedAt = $null
    if ($null -ne $PreviousMetadata) {
        $CreatedAt = Get-ObjectPropertyValue -InputObject $PreviousMetadata -Names @("createdAtUtc")
    }
    if ([string]::IsNullOrWhiteSpace("$CreatedAt")) {
        $CreatedAt = [DateTime]::UtcNow.ToString("o")
    }

    $Document = [ordered]@{
        schemaVersion = 1
        managedBy = "opencode-local-sandbox"
        sandboxName = $SandboxName
        agent = "opencode"
        projectPath = $ProjectPath
        sharedSkills = $SharedSkillsState
        managedNetworkHosts = @($ManagedNetworkHosts)
        createdAtUtc = "$CreatedAt"
        updatedAtUtc = [DateTime]::UtcNow.ToString("o")
    }

    $Directory = Join-Path $Config.ToolRoot ".local\generated\$SandboxName"
    New-Item -ItemType Directory -Force -Path $Directory | Out-Null
    $Path = Join-Path $Directory "sandbox-metadata.json"
    $Document | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Path -Encoding UTF8
    return [pscustomobject]@{
        Path = $Path
        Document = [pscustomobject]$Document
    }
}

function Sync-SandboxNetworkPolicy {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][string]$SandboxName,
        $PreviousMetadata
    )

    $Desired = @(Get-NormalizedNetworkHosts `
        -Hosts (@("localhost:$($Config.LlamaPort)") + @($Config.AdditionalNetworkHosts)) `
        -AllowUnrestricted ([bool]$Config.AllowUnrestrictedNetwork))

    $Previous = @()
    if ($null -ne $PreviousMetadata) {
        $PreviousValue = Get-ObjectPropertyValue -InputObject $PreviousMetadata -Names @("managedNetworkHosts")
        $Previous = @(Get-NormalizedNetworkHosts -Hosts @($PreviousValue) -AllowUnrestricted $true)
    }

    # Remove and recreate only the resources owned by this tool. This prevents
    # duplicate and stale allow rules while preserving unrelated user rules.
    $ManagedResources = @(Get-NormalizedNetworkHosts -Hosts (@($Previous) + @($Desired)) -AllowUnrestricted $true)
    foreach ($Resource in $ManagedResources) {
        $null = Invoke-SbxCapture -ArgumentList @(
            "policy", "rm", "network",
            "--sandbox", $SandboxName,
            "--resource", $Resource
        ) -IgnoreExitCode
    }
    if ($Desired.Count -gt 0) {
        Invoke-External "sbx" @(
            "policy", "allow", "network",
            "--sandbox", $SandboxName,
            ($Desired -join ",")
        ) | Out-Null
    }
    return @($Desired)
}

function Get-SandboxFileSha256 {
    param(
        [Parameter(Mandatory = $true)][string]$SandboxName,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $Result = Invoke-SbxCapture -ArgumentList @("exec", $SandboxName, "sha256sum", $Path)
    foreach ($Line in @($Result.Output)) {
        if ($Line -match '(?i)([0-9a-f]{64})') {
            return $Matches[1].ToLowerInvariant()
        }
    }
    throw "Impossibile verificare il file copiato nella sandbox: $Path"
}

function Assert-SandboxCopyMatches {
    param(
        [Parameter(Mandatory = $true)][string]$SandboxName,
        [Parameter(Mandatory = $true)][string]$HostPath,
        [Parameter(Mandatory = $true)][string]$SandboxPath
    )

    $HostHash = (Get-FileHash -LiteralPath $HostPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $SandboxHash = Get-SandboxFileSha256 -SandboxName $SandboxName -Path $SandboxPath
    if ($HostHash -ne $SandboxHash) {
        throw "Copia non integra verso ${SandboxName}:$SandboxPath"
    }
}

function Install-SandboxConfiguration {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][string]$SandboxName,
        [Parameter(Mandatory = $true)][string]$ProjectPath,
        [switch]$SandboxWasCreated
    )

    Assert-Command "sbx"
    Assert-Command "mkcert"

    $CARoot = (& mkcert -CAROOT).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw "Impossibile determinare la CA di mkcert."
    }
    $RootCA = Join-Path $CARoot "rootCA.pem"
    if (-not (Test-Path -LiteralPath $RootCA -PathType Leaf)) {
        throw "CA mkcert non trovata. Esegui: .\sandbox.ps1 bootstrap"
    }

    Invoke-External "sbx" @("exec", $SandboxName, "true") | Out-Null
    $PreviousMetadata = Get-SandboxToolMetadata -SandboxName $SandboxName
    $AllowedHosts = @(Sync-SandboxNetworkPolicy -Config $Config -SandboxName $SandboxName -PreviousMetadata $PreviousMetadata)

    $PreviousSharedSkills = $null
    if ($null -ne $PreviousMetadata) {
        $PreviousSharedSkills = Get-ObjectPropertyValue -InputObject $PreviousMetadata -Names @("sharedSkills")
    }
    $SharedSkillsState = if ($SandboxWasCreated) {
        if ($Config.DisableSharedSkills) { "disabled" } else { "enabled" }
    }
    elseif (-not [string]::IsNullOrWhiteSpace("$PreviousSharedSkills")) {
        "$PreviousSharedSkills"
    }
    else {
        "unknown"
    }

    $GeneratedConfig = Write-GeneratedOpenCodeConfig -Config $Config -SandboxName $SandboxName
    $GeneratedMetadata = Write-GeneratedSandboxMetadata `
        -Config $Config `
        -SandboxName $SandboxName `
        -ProjectPath $ProjectPath `
        -SharedSkillsState $SharedSkillsState `
        -ManagedNetworkHosts $AllowedHosts `
        -PreviousMetadata $PreviousMetadata

    Invoke-External "sbx" @("cp", $RootCA, "${SandboxName}:/tmp/llama-local-ca.crt") | Out-Null
    Invoke-External "sbx" @("cp", $GeneratedConfig, "${SandboxName}:/tmp/opencode-local.json") | Out-Null
    Invoke-External "sbx" @("cp", $GeneratedMetadata.Path, "${SandboxName}:/tmp/opencode-local-sandbox.json") | Out-Null

    Assert-SandboxCopyMatches -SandboxName $SandboxName -HostPath $RootCA -SandboxPath "/tmp/llama-local-ca.crt"
    Assert-SandboxCopyMatches -SandboxName $SandboxName -HostPath $GeneratedConfig -SandboxPath "/tmp/opencode-local.json"
    Assert-SandboxCopyMatches -SandboxName $SandboxName -HostPath $GeneratedMetadata.Path -SandboxPath "/tmp/opencode-local-sandbox.json"

    Invoke-External "sbx" @("exec", $SandboxName, "sudo", "mkdir", "-p", "/etc/agentbox") | Out-Null
    Invoke-External "sbx" @("exec", $SandboxName, "sudo", "install", "-m", "0644", "/tmp/llama-local-ca.crt", "/usr/local/share/ca-certificates/llama-local-ca.crt") | Out-Null
    Invoke-External "sbx" @("exec", $SandboxName, "sudo", "install", "-m", "0644", "/tmp/llama-local-ca.crt", "/etc/agentbox/llama-ca.pem") | Out-Null
    Invoke-External "sbx" @("exec", $SandboxName, "sudo", "update-ca-certificates") | Out-Null

    Invoke-External "sbx" @("exec", $SandboxName, "sudo", "install", "-m", "0644", "/tmp/opencode-local-sandbox.json", "/etc/agentbox/opencode-local-sandbox.json") | Out-Null

    $InstallOpenCode = 'mkdir -p "$HOME/.config/opencode" && install -m 0644 /tmp/opencode-local.json "$HOME/.config/opencode/opencode.json" && rm -f /tmp/opencode-local.json /tmp/opencode-local-sandbox.json /tmp/llama-local-ca.crt'
    Invoke-External "sbx" @("exec", $SandboxName, "sh", "-lc", $InstallOpenCode) | Out-Null
    return $GeneratedMetadata.Document
}

function Test-SandboxLlamaApi {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][string]$SandboxName
    )

    $Url = "https://host.docker.internal:$($Config.LlamaPort)/v1/models"
    $Result = Invoke-SbxCapture -ArgumentList @(
        "exec", $SandboxName,
        "curl", "--silent", "--show-error", "--fail",
        "--connect-timeout", "5", "--max-time", "15",
        "--cacert", "/etc/agentbox/llama-ca.pem",
        $Url
    )
    $Document = ConvertFrom-JsonCommandOutput -Output @($Result.Output)
    $Data = Get-ObjectPropertyValue -InputObject $Document -Names @("data")
    $ModelIds = foreach ($Model in @($Data)) {
        if ($null -eq $Model) {
            continue
        }
        $Identifier = Get-ObjectPropertyValue -InputObject $Model -Names @("id")
        if (-not [string]::IsNullOrWhiteSpace("$Identifier")) {
            "$Identifier"
        }
    }
    if (@($ModelIds) -notcontains $Config.ModelAlias) {
        throw "L'API raggiunta dalla sandbox non espone il modello atteso '$($Config.ModelAlias)'. Modelli: $(@($ModelIds) -join ', ')"
    }
    return $true
}

function Test-LlamaApi {
    param([Parameter(Mandatory = $true)][int]$Port)

    $Client = New-Object System.Net.Sockets.TcpClient
    try {
        $Connect = $Client.BeginConnect("127.0.0.1", $Port, $null, $null)
        if (-not $Connect.AsyncWaitHandle.WaitOne(3000, $false)) {
            return $false
        }
        $Client.EndConnect($Connect)
        return $Client.Connected
    }
    catch {
        return $false
    }
    finally {
        $Client.Dispose()
    }
}

function Get-LlamaServerLaunchInfo {
    param([Parameter(Mandatory = $true)]$Config)

    $ServerExe = Join-Path $Config.LlamaRoot "build\bin\Release\llama-server.exe"
    $ModelPath = Join-Path $Config.LlamaRoot "models\$($Config.ModelFile)"
    $KeyFile = Join-Path $Config.LlamaRoot "certs\localhost-key.pem"
    $CertFile = Join-Path $Config.LlamaRoot "certs\localhost-cert.pem"

    foreach ($RequiredFile in @($ServerExe, $ModelPath, $KeyFile, $CertFile)) {
        if (-not (Test-Path -LiteralPath $RequiredFile -PathType Leaf)) {
            throw "File richiesto non trovato: $RequiredFile"
        }
    }

    $Arguments = @(
        "-m", $ModelPath,
        "--alias", $Config.ModelAlias,
        "--host", "127.0.0.1",
        "--port", "$($Config.LlamaPort)",
        "--ctx-size", "$($Config.ContextSize)",
        "--n-gpu-layers", $Config.GpuLayers,
        "--flash-attn", "on",
        "--cache-type-k", $Config.KvCacheType,
        "--cache-type-v", $Config.KvCacheType,
        "--parallel", "1",
        "--jinja",
        "--reasoning-format", $Config.ReasoningFormat,
        "--temp", "$($Config.Temperature)",
        "--top-k", "$($Config.TopK)",
        "--top-p", "$($Config.TopP)",
        "--min-p", "$($Config.MinP)",
        "--no-context-shift",
        "--cors-origins", "localhost",
        "--no-cors-credentials",
        "--no-webui",
        "--ssl-key-file", $KeyFile,
        "--ssl-cert-file", $CertFile
    )

    return [pscustomobject]@{
        ServerExe = $ServerExe
        ModelPath = $ModelPath
        Arguments = $Arguments
    }
}

function ConvertTo-ProcessArgumentString {
    param([Parameter(Mandatory = $true)][object[]]$ArgumentList)

    $Quoted = foreach ($Argument in $ArgumentList) {
        $Value = [string]$Argument
        if ($Value.Length -eq 0) {
            '""'
        }
        elseif ($Value -notmatch '[\s"]') {
            $Value
        }
        else {
            # Current llama arguments that can contain spaces are file paths and never end in a slash.
            '"' + $Value.Replace('"', '\"') + '"'
        }
    }
    return ($Quoted -join " ")
}

function Get-LlamaListenerProcesses {
    param([Parameter(Mandatory = $true)][int]$Port)

    $Connections = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
    $ProcessIds = @($Connections | Select-Object -ExpandProperty OwningProcess -Unique)
    $Processes = foreach ($ProcessId in $ProcessIds) {
        Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    }
    return @($Processes)
}

function Assert-LlamaPortAvailable {
    param([Parameter(Mandatory = $true)]$Config)

    $Listeners = @(Get-LlamaListenerProcesses -Port ([int]$Config.LlamaPort))
    if ($Listeners.Count -eq 0) {
        return
    }

    $Details = ($Listeners | ForEach-Object { "$($_.ProcessName) (PID $($_.Id))" }) -join ", "
    throw "La porta $($Config.LlamaPort) ha gia un listener: $Details. Per evitare istanze ambigue esegui prima: .\sandbox.ps1 stop"
}

function Remove-OldLlamaLogs {
    param([Parameter(Mandatory = $true)]$Config)

    $LogDirectory = Join-Path $Config.ToolRoot ".local\logs"
    if (-not (Test-Path -LiteralPath $LogDirectory -PathType Container)) {
        return
    }
    $KeepFiles = [int]$Config.LogRetentionCount * 2
    $OldLogs = @(Get-ChildItem -LiteralPath $LogDirectory -Filter "llama-*.log" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -Skip $KeepFiles)
    foreach ($Log in $OldLogs) {
        Remove-Item -LiteralPath $Log.FullName -Force -ErrorAction SilentlyContinue
    }
}

function Start-ManagedLlamaServer {
    param([Parameter(Mandatory = $true)]$Config)

    Assert-LlamaPortAvailable -Config $Config
    $Launch = Get-LlamaServerLaunchInfo -Config $Config
    $LogDirectory = Join-Path $Config.ToolRoot ".local\logs"
    New-Item -ItemType Directory -Force -Path $LogDirectory | Out-Null
    $Stamp = Get-Date -Format "yyyyMMdd-HHmmss-fff"
    $StdOutLog = Join-Path $LogDirectory "llama-$Stamp.stdout.log"
    $StdErrLog = Join-Path $LogDirectory "llama-$Stamp.stderr.log"

    $PreviousThinking = [Environment]::GetEnvironmentVariable("LLAMA_ARG_CHAT_TEMPLATE_KWARGS", "Process")
    try {
        if ($Config.DisableThinking) {
            $env:LLAMA_ARG_CHAT_TEMPLATE_KWARGS = '{"enable_thinking":false}'
        }
        else {
            Remove-Item Env:LLAMA_ARG_CHAT_TEMPLATE_KWARGS -ErrorAction SilentlyContinue
        }

        $ArgumentString = ConvertTo-ProcessArgumentString -ArgumentList $Launch.Arguments
        $Process = Start-Process `
            -FilePath $Launch.ServerExe `
            -ArgumentList $ArgumentString `
            -WindowStyle Hidden `
            -RedirectStandardOutput $StdOutLog `
            -RedirectStandardError $StdErrLog `
            -PassThru
        Remove-OldLlamaLogs -Config $Config
    }
    finally {
        if ($null -eq $PreviousThinking) {
            Remove-Item Env:LLAMA_ARG_CHAT_TEMPLATE_KWARGS -ErrorAction SilentlyContinue
        }
        else {
            $env:LLAMA_ARG_CHAT_TEMPLATE_KWARGS = $PreviousThinking
        }
    }

    Write-Host "llama-server avviato come processo gestito (PID $($Process.Id))." -ForegroundColor Cyan
    Write-Host "Log: $StdErrLog"
    Write-Host "Attendo il caricamento del modello..." -ForegroundColor Cyan

    try {
        $Deadline = (Get-Date).AddSeconds([int]$Config.ServerStartupTimeoutSeconds)
        while ((Get-Date) -lt $Deadline) {
            $Process.Refresh()
            if ($Process.HasExited) {
                $Tail = @(Get-Content -LiteralPath $StdErrLog -Tail 30 -ErrorAction SilentlyContinue) -join [Environment]::NewLine
                throw "llama-server e terminato durante l'avvio (exit $($Process.ExitCode)).`n$Tail"
            }
            if (Test-LlamaApi -Port ([int]$Config.LlamaPort)) {
                $Owners = @(Get-LlamaListenerProcesses -Port ([int]$Config.LlamaPort))
                if ($Owners.Id -notcontains $Process.Id) {
                    throw "Il listener sulla porta $($Config.LlamaPort) non appartiene al processo appena avviato."
                }
                Write-Host "llama-server pronto." -ForegroundColor Green
                return [pscustomobject]@{
                    Process = $Process
                    Port = [int]$Config.LlamaPort
                    StdOutLog = $StdOutLog
                    StdErrLog = $StdErrLog
                }
            }
            Start-Sleep -Seconds 2
        }
        throw "llama-server non ha risposto entro $($Config.ServerStartupTimeoutSeconds) secondi. Controlla: $StdErrLog"
    }
    catch {
        $StartupError = $_
        try {
            Stop-ManagedLlamaServer -ManagedProcess $Process -Port ([int]$Config.LlamaPort)
        }
        catch {
            Write-Warning "Pulizia del server fallita dopo un errore di avvio: $($_.Exception.Message)"
        }
        throw $StartupError
    }
}

function Stop-ManagedLlamaServer {
    param(
        [Parameter(Mandatory = $true)]$ManagedProcess,
        [Parameter(Mandatory = $true)][int]$Port
    )

    $ProcessId = if ($ManagedProcess -is [System.Diagnostics.Process]) { $ManagedProcess.Id } else { [int]$ManagedProcess }
    $Process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if ($Process) {
        Write-Host "Arresto llama-server gestito (PID $ProcessId)..." -ForegroundColor Cyan
        $PreviousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            & taskkill.exe /PID $ProcessId /T /F 1>$null 2>$null
        }
        finally {
            $ErrorActionPreference = $PreviousErrorActionPreference
        }
    }

    $Deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $Deadline -and (Test-LlamaApi -Port $Port)) {
        Start-Sleep -Milliseconds 250
    }
    if (Test-LlamaApi -Port $Port) {
        throw "Il listener sulla porta $Port e ancora attivo dopo il tentativo di arresto."
    }
    Write-Host "llama-server arrestato; porta $Port libera." -ForegroundColor Green
}

function Stop-LlamaListeners {
    param([Parameter(Mandatory = $true)]$Config)

    $Listeners = @(Get-LlamaListenerProcesses -Port ([int]$Config.LlamaPort))
    if ($Listeners.Count -eq 0) {
        Write-Host "Nessun listener attivo sulla porta $($Config.LlamaPort)." -ForegroundColor Green
        return
    }

    foreach ($Listener in $Listeners) {
        if ($Listener.ProcessName -ne "llama-server") {
            throw "La porta $($Config.LlamaPort) e occupata da $($Listener.ProcessName) (PID $($Listener.Id)); non verra terminato automaticamente."
        }
        Stop-ManagedLlamaServer -ManagedProcess $Listener -Port ([int]$Config.LlamaPort)
    }
}

function Stop-SandboxSafely {
    param([Parameter(Mandatory = $true)][string]$SandboxName)

    if (@(Get-SandboxNames) -notcontains $SandboxName) {
        return
    }
    Write-Host "Arresto sandbox $SandboxName..." -ForegroundColor Cyan
    $PreviousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & sbx stop $SandboxName
        $ExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $PreviousErrorActionPreference
    }
    if ($ExitCode -ne 0) {
        throw "Impossibile arrestare la sandbox $SandboxName (exit $ExitCode)."
    }
    Write-Host "Sandbox arrestata; stato persistente conservato." -ForegroundColor Green
}
