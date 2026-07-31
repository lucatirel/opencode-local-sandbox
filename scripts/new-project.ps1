[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Name,

    [string]$ParentPath,
    [switch]$NoGit,
    [switch]$NoAttach
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "private\Common.ps1")

$Config = Get-ToolConfig
if ([string]::IsNullOrWhiteSpace($ParentPath)) {
    $ParentPath = $Config.ProjectsRoot
}

if ($Name.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or $Name -match '[\\/]') {
    throw "Nome progetto non valido: $Name"
}

New-Item -ItemType Directory -Force -Path $ParentPath | Out-Null
$ParentPath = (Resolve-Path -LiteralPath $ParentPath).Path
$ProjectPath = Join-Path $ParentPath $Name

if (Test-Path -LiteralPath $ProjectPath) {
    $Items = @(Get-ChildItem -LiteralPath $ProjectPath -Force -ErrorAction SilentlyContinue)
    if ($Items.Count -gt 0) {
        throw "La cartella esiste gia e non e vuota. Usa: .\sandbox.ps1 open `"$ProjectPath`""
    }
}
else {
    New-Item -ItemType Directory -Path $ProjectPath | Out-Null
}

if (-not $NoGit) {
    Assert-Command "git"
    Invoke-External "git" @("-C", $ProjectPath, "init") | Out-Null
    Invoke-External "git" @("-C", $ProjectPath, "branch", "-M", "main") | Out-Null
}

Write-Host "Progetto creato: $ProjectPath" -ForegroundColor Green
& (Join-Path $PSScriptRoot "open-project.ps1") -ProjectPath $ProjectPath -NoAttach:$NoAttach

