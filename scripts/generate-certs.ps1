[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "private\Common.ps1")

$Config = Get-ToolConfig
Assert-Command "mkcert"

$CertDirectory = Join-Path $Config.LlamaRoot "certs"
$KeyFile = Join-Path $CertDirectory "localhost-key.pem"
$CertFile = Join-Path $CertDirectory "localhost-cert.pem"

New-Item -ItemType Directory -Force -Path $CertDirectory | Out-Null

Write-Host "Installazione della CA locale mkcert..." -ForegroundColor Cyan
Invoke-External "mkcert" @("-install") | Out-Null

Write-Host "Generazione del certificato HTTPS..." -ForegroundColor Cyan
Invoke-External "mkcert" @(
    "-key-file", $KeyFile,
    "-cert-file", $CertFile,
    "localhost",
    "127.0.0.1",
    "::1",
    "host.docker.internal"
) | Out-Null

Write-Host "Certificato creato: $CertFile" -ForegroundColor Green
Write-Host "Chiave privata locale: $KeyFile"

