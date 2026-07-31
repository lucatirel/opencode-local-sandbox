$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\scripts\private\Common.ps1")

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) {
        throw "$Message Expected=[$Expected] Actual=[$Actual]"
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        throw $Message
    }
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Message)
    $Thrown = $false
    try {
        & $Action
    }
    catch {
        $Thrown = $true
    }
    if (-not $Thrown) {
        throw $Message
    }
}

$First = Get-ProjectSandboxName -ProjectPath "C:\Projects\Alpha App" -Prefix "oc"
$FirstAgain = Get-ProjectSandboxName -ProjectPath "C:\Projects\Alpha App" -Prefix "oc"
$Second = Get-ProjectSandboxName -ProjectPath "D:\Work\Alpha App" -Prefix "oc"

Assert-Equal $First $FirstAgain "Lo stesso percorso deve produrre lo stesso nome sandbox."
Assert-True ($First -ne $Second) "Percorsi diversi con lo stesso nome cartella devono produrre sandbox diverse."
Assert-True ($First -match '^oc-alpha-app-[0-9a-f]{8}$') "Il nome sandbox non rispetta il formato previsto: $First"

$NoisyJson = ConvertFrom-JsonCommandOutput -Output @(
    "Starting sandboxd daemon...",
    '{"sandboxes":[{"name":"oc-alpha","agent":"opencode","status":"stopped","workspaces":["C:\\Projects\\Alpha App"]}]}'
)
Assert-Equal "oc-alpha" $NoisyJson.sandboxes[0].name "Il parser deve ignorare l'output informativo prima del JSON."

$MatchingSandbox = [pscustomobject]@{
    Name = $First
    Agent = "opencode"
    Status = "stopped"
    Workspaces = @("C:\Projects\Alpha App")
}
Assert-SandboxMatchesProject -Sandbox $MatchingSandbox -ProjectPath "C:\Projects\Alpha App"
Assert-Throws { Assert-SandboxMatchesProject -Sandbox $MatchingSandbox -ProjectPath "D:\Work\Alpha App" } "Una sandbox associata a un altro workspace deve essere rifiutata."
$UnknownAgentSandbox = [pscustomobject]@{
    Name = $First
    Agent = ""
    Status = "stopped"
    Workspaces = @("C:\Projects\Alpha App")
}
Assert-Throws { Assert-SandboxMatchesProject -Sandbox $UnknownAgentSandbox -ProjectPath "C:\Projects\Alpha App" } "L'agent deve essere verificabile prima del riuso."

$NormalizedHosts = @(Get-NormalizedNetworkHosts -Hosts @("Registry.NpmJs.org:443", "registry.npmjs.org:443", "pypi.org:443"))
Assert-Equal 2 $NormalizedHosts.Count "Gli host di rete devono essere normalizzati e deduplicati."
Assert-Throws { Get-NormalizedNetworkHosts -Hosts @("**") } "La rete senza limiti deve richiedere un opt-in esplicito."

$ToolRoot = Get-ToolRoot
$FakeConfig = [pscustomobject]@{
    ToolRoot = $ToolRoot
    ModelAlias = "test-model"
    ModelDisplayName = "Test Model"
    ContextSize = 12345
    OutputTokens = 678
    LlamaPort = 9090
    Temperature = 0.25
    OpenCodePermission = "allow"
    DisableSharedSkills = $true
    SandboxMemory = "6g"
    SandboxCpus = 4
}

$Generated = Write-GeneratedOpenCodeConfig -Config $FakeConfig -SandboxName "oc-test-00000000"
try {
    $Json = Get-Content -LiteralPath $Generated -Raw | ConvertFrom-Json
    Assert-Equal "https://host.docker.internal:9090/v1" $Json.provider.'agentbox-llama'.options.baseURL "Endpoint OpenCode errato."
    Assert-Equal "agentbox-llama/test-model" $Json.model "Modello OpenCode errato."
    $GeneratedModel = $Json.provider.'agentbox-llama'.models.PSObject.Properties["test-model"].Value
    Assert-Equal 12345 $GeneratedModel.limit.context "Context limit errato."
    Assert-Equal 678 $GeneratedModel.limit.output "Output limit errato."

    $Metadata = Write-GeneratedSandboxMetadata `
        -Config $FakeConfig `
        -SandboxName "oc-test-00000000" `
        -ProjectPath "C:\Projects\Test" `
        -SharedSkillsState "disabled" `
        -ManagedNetworkHosts @("localhost:9090")
    $MetadataJson = Get-Content -LiteralPath $Metadata.Path -Raw | ConvertFrom-Json
    Assert-Equal "disabled" $MetadataJson.sharedSkills "Lo stato di isolamento deve essere persistito."
    Assert-Equal "C:\Projects\Test" $MetadataJson.projectPath "Il progetto deve essere persistito nei metadati."
}
finally {
    $GeneratedRoot = Join-Path $ToolRoot ".local\generated\oc-test-00000000"
    Remove-Item -LiteralPath $GeneratedRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$CommonSource = Get-Content -LiteralPath (Join-Path $ToolRoot "scripts\private\Common.ps1") -Raw
Assert-True ($CommonSource -match '"--sandbox"') "La policy di rete deve essere limitata alla singola sandbox."
Assert-True ($CommonSource -match '"policy", "rm", "network"') "Le policy gestite devono poter rimuovere regole obsolete."

$CreateArguments = @(Get-SandboxCreateArguments -Config $FakeConfig -SandboxName "oc-test-00000000" -ProjectPath "C:\Projects\Test")
Assert-True ($CreateArguments -contains "--no-share-skills") "Le nuove sandbox devono disabilitare lo store skill condiviso."
Assert-Equal 1 (@($CreateArguments | Where-Object { $_ -eq "C:\Projects\Test" }).Count) "Deve essere montato un solo workspace host."

$BootstrapSource = Get-Content -LiteralPath (Join-Path $ToolRoot "scripts\bootstrap.ps1") -Raw
Assert-True ($BootstrapSource -match '\$ErrorActionPreference = "Continue"') "Il probe sbx deve tollerare stderr informativo su Windows PowerShell 5.1."
Assert-True ($BootstrapSource -notmatch 'sbx ls -q \*>') "Non usare la redirezione che genera NativeCommandError con Windows PowerShell 5.1."

$CertificateSource = Get-Content -LiteralPath (Join-Path $ToolRoot "scripts\generate-certs.ps1") -Raw
Assert-True ($CertificateSource -notmatch 'mkcert.+-install') "La CA locale non deve essere installata nel trust store globale di Windows."

$ArgumentString = ConvertTo-ProcessArgumentString -ArgumentList @("-m", "C:\Models With Spaces\model.gguf", "--port", "8080")
Assert-Equal '-m "C:\Models With Spaces\model.gguf" --port 8080' $ArgumentString "Quoting degli argomenti del processo errato."

$OpenProjectSource = Get-Content -LiteralPath (Join-Path $ToolRoot "scripts\open-project.ps1") -Raw
Assert-True ($OpenProjectSource -match 'finally\s*\{') "open-project deve garantire cleanup tramite finally."
Assert-True ($OpenProjectSource -match 'Stop-ManagedLlamaServer') "open-project deve arrestare il listener gestito."
Assert-True ($OpenProjectSource -match 'Stop-SandboxSafely') "open-project deve arrestare la sandbox."
Assert-True ($OpenProjectSource -notmatch 'Start-LlamaWindowAndWait') "Non avviare listener indipendenti dal ciclo di vita della sessione."
Assert-True ($OpenProjectSource -match 'Enter-LlamaSessionLock') "open-project deve impedire gare tra listener concorrenti."
Assert-True ($OpenProjectSource -match 'Push-Location') "open-project deve gestire la cartella corrente in modo reversibile."
Assert-True ($OpenProjectSource -match 'Pop-Location') "open-project deve ripristinare la cartella PowerShell originale."
Assert-True ($OpenProjectSource -notmatch 'ReuseExistingServer') "Non riutilizzare un listener senza un protocollo di lease sicuro."

$DispatcherSource = Get-Content -LiteralPath (Join-Path $ToolRoot "sandbox.ps1") -Raw
Assert-True ($DispatcherSource -match '"stop"') "Il dispatcher deve esporre un comando stop esplicito."
Assert-True ($DispatcherSource -match '"status"') "Il dispatcher deve esporre lo stato operativo."
Assert-True ($DispatcherSource -match '"recreate"') "Il dispatcher deve esporre una migrazione esplicita delle sandbox."

$RecreateSource = Get-Content -LiteralPath (Join-Path $ToolRoot "scripts\recreate-project.ps1") -Raw
Assert-True ($RecreateSource -match 'Scrivi RICREA') "La rimozione persistente deve richiedere conferma esplicita."
Assert-True ($RecreateSource -notmatch 'Remove-Item.+ProjectPath') "La ricreazione non deve eliminare la cartella host."
Assert-True ($RecreateSource -match 'Enter-LlamaSessionLock') "La ricreazione non deve gareggiare con una sessione attiva."

$StatusSource = Get-Content -LiteralPath (Join-Path $ToolRoot "scripts\status.ps1") -Raw
Assert-True ($StatusSource -match 'Test-LlamaSessionLockAvailable') "Lo stato deve mostrare anche il lock del launcher."

Write-Host "Static functional tests passed." -ForegroundColor Green
