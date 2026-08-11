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

Assert-Equal $First $FirstAgain "Lo stesso percorso deve produrre lo stesso nome sandbox."
Assert-True ($First -ne $Second) "Percorsi diversi con lo stesso nome cartella devono produrre sandbox diverse."
Assert-True ($First -match '^oc-alpha-app-[0-9a-f]{8}$') "Il nome sandbox non rispetta il formato previsto: $First"

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
    Assert-Equal "http://host.docker.internal:9090/v1" $Json.provider.'agentbox-llama'.options.baseURL "Endpoint OpenCode errato."
    Assert-Equal "agentbox-llama/test-model" $Json.model "Modello OpenCode errato."
    Assert-Equal "allow" $Json.permission.'*' "L'agente deve essere autonomo dentro la microVM."
    $GeneratedModel = $Json.provider.'agentbox-llama'.models.PSObject.Properties["test-model"].Value
    Assert-Equal 12345 $GeneratedModel.limit.context "Context limit errato."
    Assert-Equal 678 $GeneratedModel.limit.output "Output limit errato."
}
finally {
    $GeneratedRoot = Join-Path $ToolRoot ".local\generated\oc-test-00000000"
    Remove-Item -LiteralPath $GeneratedRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$CommonSource = Get-Content -LiteralPath (Join-Path $ToolRoot "scripts\private\Common.ps1") -Raw
Assert-True ($CommonSource -match '"--sandbox"') "La policy di rete deve essere limitata alla singola sandbox."
Assert-True ($CommonSource -match '\*\*:80,\*\*:443') "Il profilo public-web deve limitare il wildcard alle porte 80/443."
Assert-True ($CommonSource -notmatch '"\*\*"\)') "Non reintrodurre allow ** senza porte: apre servizi localhost arbitrari."
Assert-True ($CommonSource -match 'localhost:80') "localhost:80 deve essere negato esplicitamente."
Assert-True ($CommonSource -match 'localhost:443') "localhost:443 deve essere negato esplicitamente."
Assert-True ($CommonSource -match 'LlamaPort.+80.+443') "Deve esistere un guardrail per LlamaPort 80/443."

$HandoffSource = Get-Content -LiteralPath (Join-Path $ToolRoot "scripts\private\GitHandoff.ps1") -Raw
Assert-True ($HandoffSource -match 'git bundle create') "L'handoff deve essere indipendente dal remote Docker tramite git bundle."
Assert-True ($HandoffSource -match 'sbx cp') "Il bundle deve essere copiato fuori dalla sandbox con sbx cp."
Assert-True ($HandoffSource -match 'bundle verify') "Il bundle deve essere verificato sul host prima dell'import."
Assert-True ($HandoffSource -match 'refs/ocbox/') "Il risultato deve finire in ref Git passivi refs/ocbox/*."

$OpenSource = Get-Content -LiteralPath (Join-Path $ToolRoot "scripts\open-project.ps1") -Raw
Assert-True ($OpenSource -match '--clone') "Il workflow hardened deve usare clone mode."
Assert-True ($OpenSource -match '--no-share-skills') "Il workflow hardened deve disabilitare shared skills."
Assert-True ($OpenSource -match 'Remove-SandboxAfterHandoff') "La distruzione deve avvenire soltanto tramite handoff verificato."

$BootstrapSource = Get-Content -LiteralPath (Join-Path $ToolRoot "scripts\bootstrap.ps1") -Raw
Assert-True ($BootstrapSource -notmatch 'mkcert') "mkcert non deve essere una dipendenza del bootstrap HTTP corrente."
Assert-True ($BootstrapSource -match '\$ErrorActionPreference = "Continue"') "Il probe sbx deve tollerare stderr informativo su Windows PowerShell 5.1."

Write-Host "Static functional tests passed." -ForegroundColor Green
