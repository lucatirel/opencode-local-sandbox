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
        $Answer = Read-Host "$Label was not found. Install it now with winget? [Y/n]"
        $ShouldInstall = [string]::IsNullOrWhiteSpace($Answer) -or $Answer -match '^[yYsS]'
    }
    if (-not $ShouldInstall) { throw "$Label is required to continue." }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw "winget is not available. Install $Label manually and rerun bootstrap."
    }

    & winget install --exact --id $WingetId --source winget
    if ($LASTEXITCODE -ne 0) { throw "$Label installation failed." }

    $MachinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $UserPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = "$MachinePath;$UserPath"

    if (-not (Get-Command $Command -ErrorAction SilentlyContinue)) {
        throw "$Label appears installed but is not available in this shell yet. Reopen PowerShell and rerun bootstrap."
    }
}

Install-ToolIfMissing -Command "sbx" -WingetId "Docker.sbx" -Label "Docker Sandboxes CLI"

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw "Git is required. Install Git and rerun bootstrap."
}

if (-not (Test-Path -LiteralPath $ConfigFile -PathType Leaf)) {
    if ([string]::IsNullOrWhiteSpace($LlamaRoot)) {
        $Candidate = Join-Path $env:USERPROFILE "llama.cpp"
        $Prompt = if (Test-Path -LiteralPath $Candidate -PathType Container) {
            "Existing llama.cpp directory [$Candidate]"
        }
        else {
            "Full path of your existing llama.cpp directory"
        }

        $LlamaRoot = Read-Host $Prompt
        if ([string]::IsNullOrWhiteSpace($LlamaRoot) -and (Test-Path -LiteralPath $Candidate -PathType Container)) {
            $LlamaRoot = $Candidate
        }
    }

    if (-not (Test-Path -LiteralPath $LlamaRoot -PathType Container)) {
        throw "llama.cpp directory not found: $LlamaRoot"
    }
    $LlamaRoot = (Resolve-Path -LiteralPath $LlamaRoot).Path

    $Server = Join-Path $LlamaRoot "build\bin\Release\llama-server.exe"
    if (-not (Test-Path -LiteralPath $Server -PathType Leaf)) {
        throw "Working llama-server.exe not found at expected path: $Server. Build llama.cpp first; OCBox does not build it."
    }

    if ([string]::IsNullOrWhiteSpace($ModelFile)) {
        $ModelsDirectory = Join-Path $LlamaRoot "models"
        $Models = @(Get-ChildItem -LiteralPath $ModelsDirectory -Filter "*.gguf" -File -ErrorAction SilentlyContinue)

        if ($Models.Count -eq 1) {
            $ModelFile = $Models[0].Name
        }
        else {
            if ($Models.Count -gt 1) {
                Write-Host "GGUF models found:" -ForegroundColor Cyan
                for ($Index = 0; $Index -lt $Models.Count; $Index++) {
                    Write-Host "  $($Index + 1). $($Models[$Index].Name)"
                }
            }
            $ModelFile = Read-Host "GGUF filename inside llama.cpp\models"
        }
    }

    $SelectedModel = Join-Path $LlamaRoot "models\$ModelFile"
    if (-not (Test-Path -LiteralPath $SelectedModel -PathType Leaf)) {
        throw "GGUF model not found: $SelectedModel"
    }

    if ([string]::IsNullOrWhiteSpace($ProjectsRoot)) {
        $DefaultProjects = Join-Path $env:USERPROFILE "Projects"
        $ProjectsRoot = Read-Host "Directory for projects created by OCBox [$DefaultProjects]"
        if ([string]::IsNullOrWhiteSpace($ProjectsRoot)) {
            $ProjectsRoot = $DefaultProjects
        }
    }

    New-Item -ItemType Directory -Force -Path $ProjectsRoot | Out-Null
    $ProjectsRoot = (Resolve-Path -LiteralPath $ProjectsRoot).Path

    $Escape = { param([string]$Value) return $Value.Replace("'", "''") }
    @(
        "# Machine-local OCBox configuration. This file is gitignored.",
        "`$LlamaRoot = '$(& $Escape $LlamaRoot)'",
        "`$ModelFile = '$(& $Escape $ModelFile)'",
        "`$ProjectsRoot = '$(& $Escape $ProjectsRoot)'"
    ) | Set-Content -LiteralPath $ConfigFile -Encoding UTF8

    Write-Host "Created: $ConfigFile" -ForegroundColor Green
}
else {
    Write-Host "Existing config.local.ps1 found; bootstrap will not overwrite it." -ForegroundColor Yellow
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
    Write-Host "Docker Sandboxes authentication is required..." -ForegroundColor Cyan
    & sbx login
    if ($LASTEXITCODE -ne 0) {
        throw "Docker Sandboxes login did not complete successfully."
    }
}

& (Join-Path $PSScriptRoot "doctor.ps1")

Write-Host ""
Write-Host "Bootstrap complete." -ForegroundColor Green
Write-Host "Run the full local gate: .\sandbox.ps1 validate"
Write-Host "Create your first project: .\sandbox.ps1 new my-project"
