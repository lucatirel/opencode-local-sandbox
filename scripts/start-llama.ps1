[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "private\Common.ps1")

$Config = Get-ToolConfig
$ServerExe = Join-Path $Config.LlamaRoot "build\bin\Release\llama-server.exe"
$ModelPath = Join-Path $Config.LlamaRoot "models\$($Config.ModelFile)"

foreach ($RequiredFile in @($ServerExe, $ModelPath)) {
    if (-not (Test-Path -LiteralPath $RequiredFile -PathType Leaf)) {
        throw "File richiesto non trovato: $RequiredFile"
    }
}

$Arguments = @(
    "-m", $ModelPath,
    "--alias", $Config.ModelAlias,
    "--load-mode", $Config.LoadMode,
    "--n-cpu-moe", "$($Config.CpuMoeLayers)",
    "--gpu-layers", $Config.GpuLayers,
    "--fit", $Config.Fit,
    "--ctx-size", "$($Config.ContextSize)",
    "--cache-type-k", $Config.KvCacheType,
    "--cache-type-v", $Config.KvCacheType,
    "--flash-attn", "on",
    "--cache-ram", "$($Config.CacheRamMiB)",
    "--parallel", "$($Config.Parallel)",
    "--batch-size", "$($Config.BatchSize)",
    "--ubatch-size", "$($Config.UBatchSize)",
    "--host", "127.0.0.1",
    "--port", "$($Config.LlamaPort)",
    "--no-ui",
    "--no-warmup",
    "--cors-origins", "localhost",
    "--no-cors-credentials"
)

Write-Host ""
Write-Host "Avvio llama-server" -ForegroundColor Cyan
Write-Host "Modello: $ModelPath"
Write-Host "Endpoint host: http://127.0.0.1:$($Config.LlamaPort)/v1"
Write-Host "Endpoint sandbox: http://host.docker.internal:$($Config.LlamaPort)/v1"
Write-Host "Contesto: $($Config.ContextSize)"
Write-Host "Preset: cpu-moe=$($Config.CpuMoeLayers), batch=$($Config.BatchSize), ubatch=$($Config.UBatchSize), KV=$($Config.KvCacheType)"
Write-Host ""

& $ServerExe @Arguments
if ($LASTEXITCODE -ne 0) {
    throw "llama-server terminato con exit code $LASTEXITCODE."
}
