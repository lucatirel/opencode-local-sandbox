$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$ConfigFile = Join-Path $RepoRoot "config.local.ps1"

if (-not (Test-Path $ConfigFile)) {
    throw "config.local.ps1 is missing. Copy config.example.ps1 to config.local.ps1 and configure it."
}

. $ConfigFile

if (-not (Get-Command mkcert -ErrorAction SilentlyContinue)) {
    throw "mkcert is not installed. Run: winget install -e --id FiloSottile.mkcert"
}

$CertDirectory = Join-Path $LlamaRoot "certs"
$KeyFile = Join-Path $CertDirectory "localhost-key.pem"
$CertFile = Join-Path $CertDirectory "localhost-cert.pem"

New-Item -ItemType Directory -Force -Path $CertDirectory | Out-Null

Write-Host "Installing the local mkcert CA..." -ForegroundColor Cyan
& mkcert -install

Write-Host "Generating the HTTPS certificate..." -ForegroundColor Cyan

& mkcert `
    -key-file $KeyFile `
    -cert-file $CertFile `
    localhost `
    127.0.0.1 `
    ::1 `
    host.docker.internal

Write-Host ""
Write-Host "Certificate created:" -ForegroundColor Green
Write-Host $CertFile
Write-Host "Private key created outside the repository:" -ForegroundColor Green
Write-Host $KeyFile
