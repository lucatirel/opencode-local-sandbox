[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$ProjectPath,
    [string]$Ref
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "private\Common.ps1")

Assert-Command "git"
$ProjectPath = Resolve-ProjectDirectory -ProjectPath $ProjectPath
Assert-GitRepository -ProjectPath $ProjectPath

if ([string]::IsNullOrWhiteSpace($Ref)) {
    $Refs = @(& git -C $ProjectPath for-each-ref --sort=-creatordate --format="%(refname)" "refs/ocbox/*/snapshot")
    if ($LASTEXITCODE -ne 0) { throw "Impossibile leggere i ref OCBox." }
    $Ref = @($Refs | ForEach-Object { "$($_)".Trim() } | Where-Object { $_ }) | Select-Object -First 1
}

if ([string]::IsNullOrWhiteSpace($Ref)) {
    throw "Nessuno snapshot OCBox trovato per questo repository."
}

$Previous = $ErrorActionPreference
try {
    $ErrorActionPreference = "Continue"
    $ShaOutput = @(& git -C $ProjectPath rev-parse --verify "$Ref^{commit}" 2>&1)
    $Code = $LASTEXITCODE
}
finally {
    $ErrorActionPreference = $Previous
}
if ($Code -ne 0 -or $ShaOutput.Count -eq 0) {
    throw "Ref snapshot non valido: $Ref"
}
$Sha = "$($ShaOutput[-1])".Trim()

Write-Host ""
Write-Host "OCBox snapshot review" -ForegroundColor Cyan
Write-Host "Project: $ProjectPath"
Write-Host "Ref:     $Ref"
Write-Host "SHA:     $Sha"
Write-Host ""
Write-Host "Changed files" -ForegroundColor Cyan
& git -C $ProjectPath diff --stat HEAD..$Ref
if ($LASTEXITCODE -ne 0) { throw "git diff --stat fallito." }

Write-Host ""
Write-Host "Patch" -ForegroundColor Cyan
& git -C $ProjectPath diff --no-ext-diff --no-textconv HEAD..$Ref
if ($LASTEXITCODE -ne 0) { throw "git diff fallito." }

Write-Host ""
Write-Host "Host working tree: NON modificato." -ForegroundColor Green
Write-Host "Per creare un branch locale senza checkout:" -ForegroundColor Cyan
Write-Host "  git -C `"$ProjectPath`" branch ocbox-review $Ref"
Write-Host "Poi ispezionalo con gli strumenti Git che preferisci prima di applicarlo/eseguirlo."
