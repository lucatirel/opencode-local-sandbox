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
    Temperature = 0.25
    OpenCodePermission = "allow"
}

$Generated = Write-GeneratedOpenCodeConfig -Config $FakeConfig -SandboxName "oc-test-00000000"
try {
    $Json = Get-Content -LiteralPath $Generated -Raw | ConvertFrom-Json
    Assert-Equal "https://host.docker.internal:9090/v1" $Json.provider.'agentbox-llama'.options.baseURL "Endpoint OpenCode errato."
    Assert-Equal "agentbox-llama/test-model" $Json.model "Modello OpenCode errato."
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

Write-Host "Static functional tests passed." -ForegroundColor Green

