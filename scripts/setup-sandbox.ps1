$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$ConfigFile = Join-Path $RepoRoot "config.local.ps1"

if (-not (Test-Path $ConfigFile)) {
    throw "config.local.ps1 is missing. Copy config.example.ps1 to config.local.ps1 and configure it."
}

. $ConfigFile

if (-not (Get-Command sbx -ErrorAction SilentlyContinue)) {
    throw "Docker Sandboxes CLI (sbx) is not installed or not available in PATH."
}

$ExistingSandboxes = @(& sbx ls -q 2>$null)

if ($ExistingSandboxes -notcontains $SandboxName) {
    Write-Host "Creating sandbox $SandboxName..." -ForegroundColor Cyan

    & sbx create `
        --name $SandboxName `
        --memory $SandboxMemory `
        --cpus $SandboxCpus `
        opencode `
        $RepoRoot
}
else {
    Write-Host "Sandbox $SandboxName already exists; creation skipped." -ForegroundColor Yellow
}

Write-Host "Allowing access to the local llama.cpp endpoint..." -ForegroundColor Cyan
& sbx policy allow network localhost:8080

if (-not (Get-Command mkcert -ErrorAction SilentlyContinue)) {
    throw "mkcert is required to install the local CA inside the sandbox."
}

$MkcertCARoot = (& mkcert -CAROOT).Trim()
$RootCA = Join-Path $MkcertCARoot "rootCA.pem"

if (-not (Test-Path $RootCA)) {
    throw "mkcert root CA not found. Run .\scripts\generate-certs.ps1 first."
}

Write-Host "Starting sandbox for certificate installation..." -ForegroundColor Cyan
& sbx exec $SandboxName -- true

Write-Host "Copying the local CA into the sandbox..." -ForegroundColor Cyan
& sbx cp $RootCA "${SandboxName}:/tmp/llama-local-ca.crt"

& sbx exec $SandboxName -- sudo mkdir -p /etc/agentbox

& sbx exec $SandboxName -- sudo install `
    -m 0644 `
    /tmp/llama-local-ca.crt `
    /usr/local/share/ca-certificates/llama-local-ca.crt

& sbx exec $SandboxName -- sudo install `
    -m 0644 `
    /tmp/llama-local-ca.crt `
    /etc/agentbox/llama-ca.pem

& sbx exec $SandboxName -- sudo update-ca-certificates

Write-Host ""
Write-Host "Sandbox setup completed." -ForegroundColor Green
Write-Host "Start it with: .\scripts\run-opencode.ps1"
