[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "private\Common.ps1")

$Config = Get-ToolConfig
$SessionLock = Enter-LlamaSessionLock -Port ([int]$Config.LlamaPort)

try {
    $Launch = Get-LlamaServerLaunchInfo -Config $Config
    Assert-LlamaPortAvailable -Config $Config

    if ($Config.DisableThinking) {
        $env:LLAMA_ARG_CHAT_TEMPLATE_KWARGS = '{"enable_thinking":false}'
    }
    else {
        Remove-Item Env:LLAMA_ARG_CHAT_TEMPLATE_KWARGS -ErrorAction SilentlyContinue
    }

    Write-Host ""
    Write-Host "Avvio llama-server" -ForegroundColor Cyan
    Write-Host "Modello: $($Launch.ModelPath)"
    Write-Host "Endpoint: https://127.0.0.1:$($Config.LlamaPort)/v1"
    Write-Host "Contesto: $($Config.ContextSize)"
    Write-Host "Questa modalita e manuale e resta in primo piano. Ctrl+C arresta direttamente il listener."
    Write-Host ""

    $ServerExe = $Launch.ServerExe
    $ServerArguments = @($Launch.Arguments)
    & $ServerExe @ServerArguments
    if ($LASTEXITCODE -ne 0) {
        throw "llama-server terminato con exit code $LASTEXITCODE."
    }
}
finally {
    Exit-LlamaSessionLock -SessionLock $SessionLock
}
