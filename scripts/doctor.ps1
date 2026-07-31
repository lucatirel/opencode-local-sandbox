[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "private\Common.ps1")

$Checks = New-Object System.Collections.Generic.List[object]
function Add-Check {
    param([string]$Name, [bool]$Ok, [string]$Detail)
    $Checks.Add([pscustomobject]@{
        Stato = if ($Ok) { "OK" } else { "ERRORE" }
        Controllo = $Name
        Dettaglio = $Detail
    })
}

$IsWindows = $env:OS -eq "Windows_NT"
Add-Check -Name "Sistema operativo" -Ok $IsWindows -Detail $(if ($IsWindows) { "Windows" } else { "questo template richiede Windows" })
Add-Check -Name "PowerShell" -Ok ($PSVersionTable.PSVersion -ge [Version]"5.1") -Detail "$($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"

$Commands = @{}
foreach ($Command in @("git", "sbx", "mkcert")) {
    $Found = Get-Command $Command -ErrorAction SilentlyContinue
    $Commands[$Command] = $Found
    Add-Check -Name "Comando $Command" -Ok ($null -ne $Found) -Detail $(if ($Found) { $Found.Source } else { "non trovato" })
}

if ($Commands["sbx"]) {
    try {
        $VersionResult = Invoke-SbxCapture -ArgumentList @("version")
        $VersionText = (($VersionResult.Output | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join " | ")
        Add-Check -Name "Versione sbx" -Ok $true -Detail $VersionText
    }
    catch {
        Add-Check -Name "Versione sbx" -Ok $false -Detail $_.Exception.Message
    }
}

$Config = $null
try {
    $Config = Get-ToolConfig
    Add-Check -Name "config.local.ps1" -Ok $true -Detail "valida: $(Join-Path (Get-ToolRoot) 'config.local.ps1')"
}
catch {
    Add-Check -Name "config.local.ps1" -Ok $false -Detail $_.Exception.Message
}

if ($Config) {
    if ($Config.DisableSharedSkills -and $Commands["sbx"]) {
        try {
            $Supported = Test-SbxSupportsNoSharedSkills
            Add-Check -Name "Isolamento skill" -Ok $Supported -Detail $(if ($Supported) { "--no-share-skills disponibile" } else { "aggiorna: winget upgrade Docker.sbx" })
        }
        catch {
            Add-Check -Name "Isolamento skill" -Ok $false -Detail $_.Exception.Message
        }
    }

    $Server = Join-Path $Config.LlamaRoot "build\bin\Release\llama-server.exe"
    $Model = Join-Path $Config.LlamaRoot "models\$($Config.ModelFile)"
    $Certificate = Join-Path $Config.LlamaRoot "certs\localhost-cert.pem"
    $PrivateKey = Join-Path $Config.LlamaRoot "certs\localhost-key.pem"

    Add-Check -Name "llama-server.exe" -Ok (Test-Path -LiteralPath $Server -PathType Leaf) -Detail $Server
    Add-Check -Name "Modello GGUF" -Ok (Test-Path -LiteralPath $Model -PathType Leaf) -Detail $Model
    Add-Check -Name "Certificato HTTPS" -Ok (Test-Path -LiteralPath $Certificate -PathType Leaf) -Detail $Certificate
    Add-Check -Name "Chiave HTTPS" -Ok (Test-Path -LiteralPath $PrivateKey -PathType Leaf) -Detail $PrivateKey

    if (Test-Path -LiteralPath $Certificate -PathType Leaf) {
        try {
            $ParsedCertificate = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList $Certificate
            $RemainingDays = [Math]::Floor(($ParsedCertificate.NotAfter.ToUniversalTime() - [DateTime]::UtcNow).TotalDays)
            Add-Check -Name "Scadenza HTTPS" -Ok ($RemainingDays -ge 7) -Detail "$($ParsedCertificate.NotAfter) ($RemainingDays giorni)"
        }
        catch {
            Add-Check -Name "Scadenza HTTPS" -Ok $false -Detail $_.Exception.Message
        }
    }

    $Listeners = @(Get-LlamaListenerProcesses -Port ([int]$Config.LlamaPort))
    if ($Listeners.Count -eq 0) {
        Add-Check -Name "Porta llama.cpp" -Ok $true -Detail "$($Config.LlamaPort) libera"
    }
    else {
        $Unexpected = @($Listeners | Where-Object { $_.ProcessName -ne "llama-server" })
        $Details = ($Listeners | ForEach-Object { "$($_.ProcessName) PID $($_.Id)" }) -join ", "
        Add-Check -Name "Porta llama.cpp" -Ok ($Unexpected.Count -eq 0) -Detail $Details
    }

    if ($Commands["sbx"]) {
        try {
            $Managed = @(Get-SandboxRecords | Where-Object { $_.Name -like "$($Config.SandboxPrefix)-*" })
            $AssociationErrors = New-Object System.Collections.Generic.List[string]
            foreach ($Sandbox in $Managed) {
                try {
                    if (@($Sandbox.Workspaces).Count -ne 1) {
                        throw "$(@($Sandbox.Workspaces).Count) workspace"
                    }
                    $ExpectedName = Get-ProjectSandboxName -ProjectPath $Sandbox.Workspaces[0] -Prefix $Config.SandboxPrefix
                    if ($ExpectedName -ne $Sandbox.Name -or $Sandbox.Agent -ine "opencode") {
                        throw "associazione nome/agent non coerente"
                    }
                }
                catch {
                    $AssociationErrors.Add("$($Sandbox.Name): $($_.Exception.Message)")
                }
            }
            $SandboxDetail = if ($AssociationErrors.Count -eq 0) { "$($Managed.Count) sandbox coerenti" } else { $AssociationErrors -join "; " }
            Add-Check -Name "Associazioni sandbox" -Ok ($AssociationErrors.Count -eq 0) -Detail $SandboxDetail
        }
        catch {
            Add-Check -Name "Associazioni sandbox" -Ok $false -Detail $_.Exception.Message
        }
    }
}

Write-Host ""
$Checks | Format-Table -AutoSize -Wrap

$Errors = @($Checks | Where-Object { $_.Stato -eq "ERRORE" })
if ($Errors.Count -gt 0) {
    throw "Doctor: $($Errors.Count) controllo/i richiesto/i non superato/i."
}

Write-Host "Doctor completato senza errori." -ForegroundColor Green
