$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$ConfigFile = Join-Path $RepoRoot "config.local.ps1"

if (-not (Test-Path $ConfigFile)) {
    throw "config.local.ps1 is missing. Copy config.example.ps1 to config.local.ps1 and configure it."
}

. $ConfigFile

$ServerExe = Join-Path $LlamaRoot "build\bin\Release\llama-server.exe"
$ModelPath = Join-Path $LlamaRoot "models\$ModelFile"
$KeyFile = Join-Path $LlamaRoot "certs\localhost-key.pem"
$CertFile = Join-Path $LlamaRoot "certs\localhost-cert.pem"

$RequiredFiles = @(
    $ServerExe,
    $ModelPath,
    $KeyFile,
    $CertFile
)

foreach ($File in $RequiredFiles) {
    if (-not (Test-Path $File)) {
        throw "Required file not found: $File"
    }
}

$env:LLAMA_ARG_CHAT_TEMPLATE_KWARGS = '{"enable_thinking":false}'

$ServerArguments = @(
    "-m", $ModelPath,
    "--alias", "qwen3-8b-q4",
    "--host", "127.0.0.1",
    "--port", "8080",
    "--ctx-size", "$ContextSize",
    "--n-gpu-layers", "all",
    "--flash-attn", "on",
    "--cache-type-k", "q4_0",
    "--cache-type-v", "q4_0",
    "--parallel", "1",
    "--jinja",
    "--reasoning-format", "deepseek",
    "--temp", "0.6",
    "--top-k", "20",
    "--top-p", "0.95",
    "--min-p", "0",
    "--no-context-shift",
    "--cors-origins", "localhost",
    "--no-cors-credentials",
    "--no-webui",
    "--ssl-key-file", $KeyFile,
    "--ssl-cert-file", $CertFile
)

Write-Host ""
Write-Host "Starting llama-server..." -ForegroundColor Cyan
Write-Host "Model: $ModelPath"
Write-Host "Context: $ContextSize"
Write-Host ""

& $ServerExe @ServerArguments
