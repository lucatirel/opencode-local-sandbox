[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "private\Common.ps1")
. (Join-Path $PSScriptRoot "private\GitHandoff.ps1")

Assert-Command "sbx"
Assert-Command "git"

$Nonce = [Guid]::NewGuid().ToString("N").Substring(0, 8)
$Sandbox = "oc-handoff-$Nonce"
$Root = Join-Path $env:TEMP "ocbox-handoff-$Nonce"
$Repo = Join-Path $Root "repo"
$SessionId = Get-HandoffSessionId
$ExpectedText = "sandbox-only-$Nonce"
$Handoff = $null
$SandboxRemoved = $false

New-Item -ItemType Directory -Force -Path $Repo | Out-Null
"host baseline" | Set-Content -LiteralPath (Join-Path $Repo "README.txt") -Encoding ASCII
& git -C $Repo init -q
& git -C $Repo add README.txt
& git -C $Repo -c user.name="OCBox Handoff Test" -c user.email="handoff-test@localhost" commit -q -m "baseline"
if ($LASTEXITCODE -ne 0) { throw "Impossibile creare il repository Git temporaneo." }

$HostHeadBefore = (& git -C $Repo rev-parse HEAD).Trim()
$HostStatusBefore = (@(& git -C $Repo status --porcelain=v1) -join "`n")

try {
    Write-Host "Creo sandbox clone-mode usa-e-getta: $Sandbox" -ForegroundColor Cyan
    Invoke-External "sbx" @("create", "--name", $Sandbox, "--clone", "--no-share-skills", "shell", $Repo) | Out-Null

    Write-Host "Creo modifiche solo nel clone privato..." -ForegroundColor DarkGray
    $Write = Invoke-SandboxShellCapture -SandboxName $Sandbox -Command "printf '%s\n' '$ExpectedText' > handoff-proof.txt && printf '%s\n' 'second change' >> README.txt"
    if ($Write.Code -ne 0) { throw "Impossibile creare la modifica nella sandbox: $($Write.Text)" }

    if (Test-Path -LiteralPath (Join-Path $Repo "handoff-proof.txt")) {
        throw "FAIL: la modifica sandbox e comparsa nel working tree host prima dell'handoff."
    }

    Write-Host "Creo snapshot Git nella microVM..." -ForegroundColor DarkGray
    $Snapshot = New-SandboxGitSnapshot -SandboxName $Sandbox -SessionId $SessionId
    if ($Snapshot.IgnoredCount -gt 0) {
        throw "Il test ha prodotto file ignored non preservati ($($Snapshot.IgnoredCount)); non distruggo la sandbox."
    }

    Write-Host "Fetch in namespace passivo refs/ocbox/..." -ForegroundColor DarkGray
    $Handoff = Export-SandboxGitHandoff -ProjectPath $Repo -SandboxName $Sandbox -SessionId $SessionId -Snapshot $Snapshot

    $HostHeadAfterFetch = (& git -C $Repo rev-parse HEAD).Trim()
    $HostStatusAfterFetch = (@(& git -C $Repo status --porcelain=v1) -join "`n")
    if ($HostHeadAfterFetch -ne $HostHeadBefore -or $HostStatusAfterFetch -ne $HostStatusBefore) {
        throw "FAIL: fetch handoff ha modificato HEAD o working tree host."
    }

    $Proof = (& git -C $Repo show "$($Handoff.SnapshotRef):handoff-proof.txt").Trim()
    if ($LASTEXITCODE -ne 0 -or $Proof -ne $ExpectedText) {
        throw "FAIL: il ref passivo non contiene il file sandbox atteso."
    }

    Write-Host "Distruggo la sandbox dopo handoff verificato..." -ForegroundColor DarkGray
    Remove-SandboxAfterHandoff -SandboxName $Sandbox -ProjectPath $Repo -Handoff $Handoff
    $SandboxRemoved = $true

    $ProofAfterRm = (& git -C $Repo show "$($Handoff.SnapshotRef):handoff-proof.txt").Trim()
    if ($LASTEXITCODE -ne 0 -or $ProofAfterRm -ne $ExpectedText) {
        throw "FAIL: il ref handoff non e sopravvissuto a sbx rm."
    }

    $HostHeadFinal = (& git -C $Repo rev-parse HEAD).Trim()
    $HostStatusFinal = (@(& git -C $Repo status --porcelain=v1) -join "`n")
    if ($HostHeadFinal -ne $HostHeadBefore -or $HostStatusFinal -ne $HostStatusBefore) {
        throw "FAIL: working tree host modificato dopo distruzione sandbox."
    }

    Write-Host ""
    Write-Host "GIT HANDOFF: PASS" -ForegroundColor Green
    Write-Host "  Host HEAD invariato: $HostHeadFinal" -ForegroundColor Green
    Write-Host "  Snapshot preservato: $($Handoff.SnapshotRef) -> $($Handoff.SnapshotSha)" -ForegroundColor Green
    Write-Host "  Sandbox distrutta: $Sandbox" -ForegroundColor Green
    Write-Host "  Working tree host: invariato" -ForegroundColor Green
}
finally {
    if (-not $SandboxRemoved) {
        Write-Warning "Test non completato: provo a lasciare intatta la sandbox se esiste per diagnosi."
    }
    Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue
}
