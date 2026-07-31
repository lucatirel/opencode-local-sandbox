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

    # Loading defaults before local values keeps old, shorter config.local.ps1 files compatible.
    . $ExampleFile
    . $LocalFile

    return [pscustomobject]@{
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
        OpenCodePermission        = $OpenCodePermission
        AdditionalNetworkHosts    = @($AdditionalNetworkHosts)
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
    $PreviousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $Output = @(& sbx ls -q 2>$null)
        $ExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $PreviousErrorActionPreference
    }
    if ($ExitCode -ne 0) {
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
                Stop-ManagedLlamaServer -ManagedProcess $Process -Port ([int]$Config.LlamaPort)
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

    Stop-ManagedLlamaServer -ManagedProcess $Process -Port ([int]$Config.LlamaPort)
    throw "llama-server non ha risposto entro $($Config.ServerStartupTimeoutSeconds) secondi. Controlla: $StdErrLog"
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
