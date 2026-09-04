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
if ($LASTEXITCODE -ne 0) { throw "Could not create the temporary Git repository." }

$HostHeadBefore = (& git -C $Repo rev-parse HEAD).Trim()
$HostStatusBefore = (@(& git -C $Repo status --porcelain=v1) -join "`n")

try {
    Write-Host "Creating disposable clone-mode shell sandbox: $Sandbox" -ForegroundColor Cyan

    # This test exercises the sandbox/Git lifecycle only. Keeping it on the
    # lightweight shell template avoids coupling the handoff gate to OpenCode or a model.
    Invoke-External "sbx" @("create", "--name", $Sandbox, "--clone", "--no-share-skills", "shell", $Repo) | Out-Null

    Write-Host "Creating changes inside the private clone..." -ForegroundColor DarkGray
    $Write = Invoke-SandboxShellCapture -SandboxName $Sandbox -Command "printf '%s\n' '$ExpectedText' > handoff-proof.txt && printf '%s\n' 'second change' >> README.txt"
    if ($Write.Code -ne 0) { throw "Could not create the sandbox change: $($Write.Text)" }

    if (Test-Path -LiteralPath (Join-Path $Repo "handoff-proof.txt")) {
        throw "FAIL: a sandbox-only change appeared in the host working tree before handoff."
    }

    Write-Host "Creating the Git snapshot inside the sandbox..." -ForegroundColor DarkGray
    $Snapshot = New-SandboxGitSnapshot -SandboxName $Sandbox -SessionId $SessionId
    if ($Snapshot.IgnoredCount -gt 0) {
        throw "The test produced ignored files that cannot be preserved ($($Snapshot.IgnoredCount)); the sandbox will not be destroyed."
    }

    Write-Host "Importing into passive refs/ocbox/... namespace..." -ForegroundColor DarkGray
    $Handoff = Export-SandboxGitHandoff -ProjectPath $Repo -SandboxName $Sandbox -SessionId $SessionId -Snapshot $Snapshot

    $HostHeadAfterFetch = (& git -C $Repo rev-parse HEAD).Trim()
    $HostStatusAfterFetch = (@(& git -C $Repo status --porcelain=v1) -join "`n")
    if ($HostHeadAfterFetch -ne $HostHeadBefore -or $HostStatusAfterFetch -ne $HostStatusBefore) {
        throw "FAIL: handoff fetch modified the host HEAD or working tree."
    }

    $Proof = (& git -C $Repo show "$($Handoff.SnapshotRef):handoff-proof.txt").Trim()
    if ($LASTEXITCODE -ne 0 -or $Proof -ne $ExpectedText) {
        throw "FAIL: the passive ref does not contain the expected sandbox file."
    }

    Write-Host "Destroying the sandbox after verified handoff..." -ForegroundColor DarkGray
    Remove-SandboxAfterHandoff -SandboxName $Sandbox -ProjectPath $Repo -Handoff $Handoff
    $SandboxRemoved = $true

    $ProofAfterRm = (& git -C $Repo show "$($Handoff.SnapshotRef):handoff-proof.txt").Trim()
    if ($LASTEXITCODE -ne 0 -or $ProofAfterRm -ne $ExpectedText) {
        throw "FAIL: the handoff ref did not survive sandbox destruction."
    }

    $HostHeadFinal = (& git -C $Repo rev-parse HEAD).Trim()
    $HostStatusFinal = (@(& git -C $Repo status --porcelain=v1) -join "`n")
    if ($HostHeadFinal -ne $HostHeadBefore -or $HostStatusFinal -ne $HostStatusBefore) {
        throw "FAIL: host working tree changed after sandbox destruction."
    }

    Write-Host ""
    Write-Host "GIT HANDOFF: PASS" -ForegroundColor Green
    Write-Host "  Host HEAD unchanged: $HostHeadFinal" -ForegroundColor Green
    Write-Host "  Snapshot preserved: $($Handoff.SnapshotRef) -> $($Handoff.SnapshotSha)" -ForegroundColor Green
    Write-Host "  Sandbox destroyed: $Sandbox" -ForegroundColor Green
    Write-Host "  Host working tree: unchanged" -ForegroundColor Green
}
finally {
    if (-not $SandboxRemoved) {
        Write-Warning "Test did not complete; any existing sandbox is intentionally left intact for diagnosis."
    }
    Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue
}
