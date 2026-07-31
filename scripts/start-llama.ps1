[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "private\Common.ps1")

$Config = Get-ToolConfig
$ServerExe = Join-Path $Config.LlamaRoot "build\bin\Release\llama-server.exe"
$ModelPath = Join-Path $Config.LlamaRoot "models\$($Config.ModelFile)"
$KeyFile = Join-Path $Config.LlamaRoot "certs\localhost-key.pem"
$CertFile = Join-Path $Config.LlamaRoot "certs\localhost-cert.pem"

foreach ($RequiredFile in @($ServerExe, $ModelPath, $KeyFile, $CertFile)) {
    if (-not (Test-Path -LiteralPath $RequiredFile -PathType Leaf)) {
        throw "File richiesto non trovato: $RequiredFile"
    }
}

if ($Config.DisableThinking) {
    $env:LLAMA_ARG_CHAT_TEMPLATE_KWARGS = '{"enable_thinking":false}'
}
else {
    Remove-Item Env:LLAMA_ARG_CHAT_TEMPLATE_KWARGS -ErrorAction SilentlyContinue
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

Write-Host ""
Write-Host "Avvio llama-server" -ForegroundColor Cyan
Write-Host "Modello: $ModelPath"
Write-Host "Endpoint: https://127.0.0.1:$($Config.LlamaPort)/v1"
Write-Host "Contesto: $($Config.ContextSize)"
Write-Host ""

& $ServerExe @Arguments
if ($LASTEXITCODE -ne 0) {
    throw "llama-server terminato con exit code $LASTEXITCODE."
}

