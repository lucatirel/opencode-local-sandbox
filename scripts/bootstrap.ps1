[CmdletBinding()]
param(
    [string]$LlamaRoot,
    [string]$ModelFile,
    [string]$ProjectsRoot,
    [switch]$InstallMissing
)

$ErrorActionPreference = "Stop"
$ToolRoot = Split-Path -Parent $PSScriptRoot
$ConfigFile = Join-Path $ToolRoot "config.local.ps1"

function Install-ToolIfMissing {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string]$WingetId,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if (Get-Command $Command -ErrorAction SilentlyContinue) { return }

    $ShouldInstall = $InstallMissing
    if (-not $ShouldInstall) {
        $Answer = Read-Host "$Label non trovato. Installarlo ora con winget? [S/n]"
        $ShouldInstall = [string]::IsNullOrWhiteSpace($Answer) -or $Answer -match '^[sSyY]'
    }
    if (-not $ShouldInstall) { throw "$Label e richiesto per continuare." }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw "winget non disponibile: installa manualmente $Label."
    }

    & winget install --exact --id $WingetId --source winget
    if ($LASTEXITCODE -ne 0) { throw "Installazione di $Label fallita." }

    $MachinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $UserPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = "$MachinePath;$UserPath"
    if (-not (Get-Command $Command -ErrorAction SilentlyContinue)) {
        throw "$Label risulta installato ma non e ancora disponibile. Riapri PowerShell e rilancia il bootstrap."
    }
}

Install-ToolIfMissing -Command "sbx" -WingetId "Docker.sbx" -Label "Docker Sandboxes CLI"

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw "Git non e disponibile. Installalo prima di continuare."
}

if (-not (Test-Path -LiteralPath $ConfigFile -PathType Leaf)) {
    if ([string]::IsNullOrWhiteSpace($LlamaRoot)) {
        $Candidate = Join-Path $env:USERPROFILE "Desktop\Git\llama.cpp"
        $Prompt = if (Test-Path -LiteralPath $Candidate -PathType Container) { "Percorso llama.cpp [$Candidate]" } else { "Percorso completo della cartella llama.cpp" }
        $LlamaRoot = Read-Host $Prompt
        if ([string]::IsNullOrWhiteSpace($LlamaRoot) -and (Test-Path -LiteralPath $Candidate -PathType Container)) { $LlamaRoot = $Candidate }
    }
    if (-not (Test-Path -LiteralPath $LlamaRoot -PathType Container)) { throw "Cartella llama.cpp non trovata: $LlamaRoot" }
    $LlamaRoot = (Resolve-Path -LiteralPath $LlamaRoot).Path

    if ([string]::IsNullOrWhiteSpace($ModelFile)) {
        $ModelsDirectory = Join-Path $LlamaRoot "models"
        $Models = @(Get-ChildItem -LiteralPath $ModelsDirectory -Filter "*.gguf" -File -ErrorAction SilentlyContinue)
        if ($Models.Count -eq 1) {
            $ModelFile = $Models[0].Name
        }
        else {
            if ($Models.Count -gt 1) {
                Write-Host "Modelli trovati:" -ForegroundColor Cyan
                for ($Index = 0; $Index -lt $Models.Count; $Index++) { Write-Host "  $($Index + 1). $($Models[$Index].Name)" }
            }
            $ModelFile = Read-Host "Nome del file GGUF dentro llama.cpp\models"
        }
    }
    $SelectedModel = Join-Path $LlamaRoot "models\$ModelFile"
    if (-not (Test-Path -LiteralPath $SelectedModel -PathType Leaf)) { throw "Modello GGUF non trovato: $SelectedModel" }

    if ([string]::IsNullOrWhiteSpace($ProjectsRoot)) {
        $DefaultProjects = Join-Path $env:USERPROFILE "Projects"
        $ProjectsRoot = Read-Host "Cartella in cui creare i progetti [$DefaultProjects]"
        if ([string]::IsNullOrWhiteSpace($ProjectsRoot)) { $ProjectsRoot = $DefaultProjects }
    }
    New-Item -ItemType Directory -Force -Path $ProjectsRoot | Out-Null
    $ProjectsRoot = (Resolve-Path -LiteralPath $ProjectsRoot).Path

    $Escape = { param([string]$Value) return $Value.Replace("'", "''") }
    @(
        "# File locale: non viene committato.",
        "`$LlamaRoot = '$(& $Escape $LlamaRoot)'",
        "`$ModelFile = '$(& $Escape $ModelFile)'",
        "`$ProjectsRoot = '$(& $Escape $ProjectsRoot)'"
    ) | Set-Content -LiteralPath $ConfigFile -Encoding UTF8
    Write-Host "Creato: $ConfigFile" -ForegroundColor Green
}
else {
    Write-Host "Configurazione locale gia presente; non viene sovrascritta." -ForegroundColor Yellow
}

$PreviousErrorActionPreference = $ErrorActionPreference
try {
    $ErrorActionPreference = "Continue"
    & sbx ls -q 1>$null 2>$null
    $SbxListExitCode = $LASTEXITCODE
}
finally {
    $ErrorActionPreference = $PreviousErrorActionPreference
}

if ($SbxListExitCode -ne 0) {
    Write-Host "Accesso a Docker Sandboxes richiesto..." -ForegroundColor Cyan
    & sbx login
    if ($LASTEXITCODE -ne 0) { throw "Login Docker Sandboxes non completato." }
}

& (Join-Path $PSScriptRoot "doctor.ps1")

Write-Host ""
Write-Host "Bootstrap completato." -ForegroundColor Green
Write-Host "Verifica isolamento: .\sandbox.ps1 security-test"
Write-Host "Crea il primo progetto: .\sandbox.ps1 new nome-progetto"
