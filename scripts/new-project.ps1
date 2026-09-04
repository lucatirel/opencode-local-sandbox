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
    throw "Invalid project name: $Name"
}

New-Item -ItemType Directory -Force -Path $ParentPath | Out-Null
$ParentPath = (Resolve-Path -LiteralPath $ParentPath).Path
$ProjectPath = Join-Path $ParentPath $Name

if (Test-Path -LiteralPath $ProjectPath) {
    $Items = @(Get-ChildItem -LiteralPath $ProjectPath -Force -ErrorAction SilentlyContinue)
    if ($Items.Count -gt 0) {
        throw "The directory already exists and is not empty. Use: .\sandbox.ps1 open `"$ProjectPath`""
    }
}
else {
    New-Item -ItemType Directory -Path $ProjectPath | Out-Null
}

if (-not $NoGit) {
    Assert-Command "git"

    $Readme = Join-Path $ProjectPath "README.md"
    "# $Name" | Set-Content -LiteralPath $Readme -Encoding UTF8

    Invoke-External "git" @("-C", $ProjectPath, "init", "-q") | Out-Null
    Invoke-External "git" @("-C", $ProjectPath, "branch", "-M", "main") | Out-Null
    Invoke-External "git" @("-C", $ProjectPath, "add", "README.md") | Out-Null

    # Clone mode needs a valid HEAD. Use an ephemeral identity for this bootstrap
    # commit so OCBox does not require or modify the user's global Git identity.
    Invoke-External "git" @(
        "-C", $ProjectPath,
        "-c", "user.name=OCBox Bootstrap",
        "-c", "user.email=ocbox@localhost",
        "commit", "-q", "-m", "Initial commit"
    ) | Out-Null
}

Write-Host "Project created: $ProjectPath" -ForegroundColor Green

if ($NoGit -and $Config.UseCloneMode) {
    throw "-NoGit cannot be opened with the hardened clone-mode profile. Initialize Git first."
}

& (Join-Path $PSScriptRoot "open-project.ps1") -ProjectPath $ProjectPath -NoAttach:$NoAttach
