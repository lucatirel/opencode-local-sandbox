[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$ProjectPath,

    [string]$SandboxName,
    [switch]$NoAttach
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "private\Common.ps1")

$Config = Get-ToolConfig
Assert-Command "sbx"
Assert-Command "mkcert"

$ProjectPath = Resolve-ProjectDirectory -ProjectPath $ProjectPath
if ([string]::IsNullOrWhiteSpace($SandboxName)) {
    $SandboxName = Get-ProjectSandboxName -ProjectPath $ProjectPath -Prefix $Config.SandboxPrefix
}

$SessionLock = Enter-LlamaSessionLock -Port ([int]$Config.LlamaPort)
$ManagedServer = $null
$SandboxWasCreated = $false
$ShouldStopSandbox = $false
$LocationPushed = $false
$PrimaryError = $null
$CleanupErrors = New-Object System.Collections.Generic.List[string]
try {
    $Sandbox = Get-SandboxRecord -SandboxName $SandboxName
    if ($null -eq $Sandbox) {
        $ShouldStopSandbox = $true
        $Sandbox = New-ProjectSandbox -Config $Config -SandboxName $SandboxName -ProjectPath $ProjectPath
        $SandboxWasCreated = $true
    }
    else {
        Assert-SandboxMatchesProject -Sandbox $Sandbox -ProjectPath $ProjectPath
        Write-Host "Sandbox esistente: $SandboxName" -ForegroundColor Yellow
        $ShouldStopSandbox = $true
    }

    if (-not $NoAttach) {
        $ManagedServer = Start-ManagedLlamaServer -Config $Config
    }

    Write-Host "Aggiornamento CA, configurazione OpenCode e policy locale..." -ForegroundColor Cyan
    $Metadata = Install-SandboxConfiguration `
        -Config $Config `
        -SandboxName $SandboxName `
        -ProjectPath $ProjectPath `
        -SandboxWasCreated:$SandboxWasCreated

    if ($Config.DisableSharedSkills -and $Metadata.sharedSkills -ne "disabled") {
        Write-Warning "Questa sandbox e precedente all'isolamento delle skill condivise. Per chiudere anche quel confine: .\sandbox.ps1 recreate `"$ProjectPath`""
    }

    if (-not $NoAttach) {
        Write-Host "Verifica HTTPS e modello dalla sandbox..." -ForegroundColor Cyan
        $null = Test-SandboxLlamaApi -Config $Config -SandboxName $SandboxName
    }

    Write-Host ""
    Write-Host "Progetto: $ProjectPath" -ForegroundColor Green
    Write-Host "Sandbox: $SandboxName" -ForegroundColor Green
    Write-Host "La sandbox vede in scrittura soltanto il workspace montato."
    Write-Host "Ctrl+C chiudera OpenCode, fermera la sandbox e liberera la GPU."
    Write-Host ""

    if (-not $NoAttach) {
        Push-Location -LiteralPath $ProjectPath
        $LocationPushed = $true
        & sbx run --name $SandboxName
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "OpenCode/sbx terminato con exit code $LASTEXITCODE."
        }
    }
}
catch {
    $PrimaryError = $_
    throw
}
finally {
    if ($LocationPushed) {
        try {
            Pop-Location
        }
        catch {
            $CleanupErrors.Add("Impossibile ripristinare la cartella PowerShell: $($_.Exception.Message)")
        }
    }

    if ($ShouldStopSandbox) {
        try {
            Stop-SandboxSafely -SandboxName $SandboxName
        }
        catch {
            $CleanupErrors.Add($_.Exception.Message)
        }
    }
    if ($ManagedServer) {
        try {
            Stop-ManagedLlamaServer -ManagedProcess $ManagedServer.Process -Port $ManagedServer.Port
        }
        catch {
            $CleanupErrors.Add($_.Exception.Message)
        }
    }
    try {
        Exit-LlamaSessionLock -SessionLock $SessionLock
    }
    catch {
        $CleanupErrors.Add("Impossibile rilasciare il lock di sessione: $($_.Exception.Message)")
    }

    if ($CleanupErrors.Count -gt 0) {
        foreach ($CleanupError in $CleanupErrors) {
            Write-Warning "Pulizia: $CleanupError"
        }
        if ($null -eq $PrimaryError) {
            throw "Sessione terminata, ma la pulizia non e stata completata. Esegui: .\sandbox.ps1 stop `"$ProjectPath`""
        }
    }
}
