[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$ProjectPath,
    [string]$SandboxName
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "private\Common.ps1")
. (Join-Path $PSScriptRoot "private\GitHandoff.ps1")

$Config = Get-ToolConfig
Assert-Command "sbx"
Assert-Command "git"

$ProjectPath = Resolve-ProjectDirectory -ProjectPath $ProjectPath
Assert-GitRepository -ProjectPath $ProjectPath

if ([string]::IsNullOrWhiteSpace($SandboxName)) {
    $SandboxName = Get-ProjectSandboxName -ProjectPath $ProjectPath -Prefix $Config.SandboxPrefix
    if ($Config.UseCloneMode) {
        $SandboxName = "$SandboxName-clone"
    }
}

$Existing = @(Get-SandboxNames)
if ($Existing -notcontains $SandboxName) {
    throw "Sandbox non trovata: $SandboxName"
}

$SessionId = Get-HandoffSessionId
Write-Host "Recupero sandbox esistente: $SandboxName" -ForegroundColor Cyan
Write-Host "Creo snapshot Git nella microVM..." -ForegroundColor DarkGray
$Snapshot = New-SandboxGitSnapshot -SandboxName $SandboxName -SessionId $SessionId

Write-Host "Fetch sul host in refs/ocbox/..." -ForegroundColor DarkGray
$Handoff = Export-SandboxGitHandoff -ProjectPath $ProjectPath -SandboxName $SandboxName -SessionId $SessionId -Snapshot $Snapshot

Write-Host "Snapshot verificato: $($Handoff.SnapshotRef)" -ForegroundColor Green
Write-Host "SHA: $($Handoff.SnapshotSha)" -ForegroundColor DarkGray
Write-Host "Distruggo la sandbox solo dopo la verifica..." -ForegroundColor DarkGray
Remove-SandboxAfterHandoff -SandboxName $SandboxName -ProjectPath $ProjectPath -Handoff $Handoff

Write-Host ""
Write-Host "GIT HANDOFF: PASS" -ForegroundColor Green
Write-Host "  Snapshot: $($Handoff.SnapshotRef)" -ForegroundColor Green
Write-Host "  SHA: $($Handoff.SnapshotSha)" -ForegroundColor Green
Write-Host "  Sandbox distrutta: $SandboxName" -ForegroundColor Green
Write-Host "  Working tree host: non modificato" -ForegroundColor Green
Write-Host ""
Write-Host "Ispeziona senza checkout:" -ForegroundColor Cyan
Write-Host "  git -C `"$ProjectPath`" diff HEAD..$($Handoff.SnapshotRef)"
Write-Host "  git -C `"$ProjectPath`" show $($Handoff.SnapshotRef):<file>"
