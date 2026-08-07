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
        LlamaPort                   = $LlamaPort
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

function Get-SandboxNames {
    Assert-Command "sbx"

    # Windows PowerShell 5.1 turns harmless native stderr (for example
    # "Starting sandboxd daemon...") into a terminating NativeCommandError
    # when ErrorActionPreference is Stop. Probe sbx with Continue and judge
    # success from its actual process exit code instead.
    $PreviousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $Output = @(& sbx ls -q 2>$null)
        $SbxListExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $PreviousErrorActionPreference
    }

    if ($SbxListExitCode -ne 0) {
        throw "Impossibile leggere le sandbox. Prova: sbx login"
    }
    return @($Output | ForEach-Object { "$($_)".Trim() } | Where-Object { $_ })
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

    $Permissions = [ordered]@{
        "*"                = "deny"
        read               = "allow"
        edit               = "allow"
        glob               = "allow"
        grep               = "allow"
        list               = "allow"
        bash               = "ask"
        external_directory = "deny"
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
        permission = $Permissions
        agent = [ordered]@{
            title = [ordered]@{ disable = $true }
        }
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
    Assert-Command "mkcert"

    $AllowedHosts = @("localhost:$($Config.LlamaPort)") + @($Config.AdditionalNetworkHosts)
    $AllowedHosts = @($AllowedHosts | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    Invoke-External "sbx" @("policy", "allow", "network", "--sandbox", $SandboxName, ($AllowedHosts -join ",")) | Out-Null

    $CARoot = (& mkcert -CAROOT).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw "Impossibile determinare la CA di mkcert."
    }
    $RootCA = Join-Path $CARoot "rootCA.pem"
    if (-not (Test-Path -LiteralPath $RootCA -PathType Leaf)) {
        throw "CA mkcert non trovata. Esegui: .\sandbox.ps1 bootstrap"
    }

    $GeneratedConfig = Write-GeneratedOpenCodeConfig -Config $Config -SandboxName $SandboxName

    Invoke-External "sbx" @("exec", $SandboxName, "true") | Out-Null
    Invoke-External "sbx" @("cp", $RootCA, "${SandboxName}:/tmp/llama-local-ca.crt") | Out-Null
    Invoke-External "sbx" @("cp", $GeneratedConfig, "${SandboxName}:/tmp/opencode-local.json") | Out-Null

    Invoke-External "sbx" @("exec", $SandboxName, "sudo", "mkdir", "-p", "/etc/agentbox") | Out-Null
    Invoke-External "sbx" @("exec", $SandboxName, "sudo", "install", "-m", "0644", "/tmp/llama-local-ca.crt", "/usr/local/share/ca-certificates/llama-local-ca.crt") | Out-Null
    Invoke-External "sbx" @("exec", $SandboxName, "sudo", "install", "-m", "0644", "/tmp/llama-local-ca.crt", "/etc/agentbox/llama-ca.pem") | Out-Null
    Invoke-External "sbx" @("exec", $SandboxName, "sudo", "update-ca-certificates") | Out-Null

    $InstallOpenCode = 'mkdir -p "$HOME/.config/opencode" && install -m 0644 /tmp/opencode-local.json "$HOME/.config/opencode/opencode.json"'
    Invoke-External "sbx" @("exec", $SandboxName, "sh", "-lc", $InstallOpenCode) | Out-Null
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

function Start-LlamaWindowAndWait {
    param([Parameter(Mandatory = $true)]$Config)

    $Script = Join-Path $Config.ToolRoot "scripts\start-llama.ps1"
    $QuotedScript = '"' + $Script + '"'
    Start-Process -FilePath "powershell.exe" -ArgumentList "-NoExit -ExecutionPolicy Bypass -File $QuotedScript" | Out-Null

    $Deadline = (Get-Date).AddSeconds([int]$Config.ServerStartupTimeoutSeconds)
    Write-Host "Attendo che llama-server carichi il modello..." -ForegroundColor Cyan
    while ((Get-Date) -lt $Deadline) {
        if (Test-LlamaApi -Port ([int]$Config.LlamaPort)) {
            Write-Host "llama-server pronto." -ForegroundColor Green
            return $true
        }
        Start-Sleep -Seconds 2
    }

    Write-Warning "llama-server non ha risposto entro $($Config.ServerStartupTimeoutSeconds) secondi. Controlla la finestra del server."
    return $false
}
