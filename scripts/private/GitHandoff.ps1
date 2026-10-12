Set-StrictMode -Version 3.0

function Invoke-SandboxShellCapture {
    param(
        [Parameter(Mandatory = $true)][string]$SandboxName,
        [Parameter(Mandatory = $true)][string]$Command
    )

    $LinuxCommand = $Command.Replace("`r`n", "`n").Replace("`r", "")

    $Previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $Output = @(& sbx exec $SandboxName bash -c $LinuxCommand 2>&1)
        $Code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $Previous }

    return [pscustomobject]@{
        Code = $Code
        Text = (($Output | ForEach-Object { "$($_)" }) -join "`n").Trim()
    }
}

function Get-HandoffSessionId {
    $Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $Nonce = [Guid]::NewGuid().ToString("N").Substring(0, 8)
    return "$Stamp-$Nonce"
}

function New-SandboxGitSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$SandboxName,
        [Parameter(Mandatory = $true)][string]$SessionId
    )

    if ($SessionId -notmatch '^[0-9A-Za-z._-]+$') {
        throw "SessionId Git non valido: $SessionId"
    }

    $SnapshotBranch = "ocbox-snapshot-$SessionId"
    $Message = "ocbox snapshot $SessionId"
    # A static shell resource keeps quoting out of the preservation rules and
    # lets the same guard run in integration fixtures with real Git.
    $GuardCommand = Get-Content -LiteralPath (Join-Path $PSScriptRoot "preservation-guard.sh") -Raw

    $Guard = Invoke-SandboxShellCapture -SandboxName $SandboxName -Command $GuardCommand
    switch ($Guard.Code) {
        42 { throw "La sandbox contiene file gitignored non preservabili automaticamente. Sandbox conservata. Output: $($Guard.Text)" }
        43 { throw "La sandbox contiene worktree Git secondari. Handoff automatico non sicuro: sandbox conservata. Output: $($Guard.Text)" }
        44 { throw "Il repository usa Git LFS. Un Git bundle non preserva gli oggetti LFS: sandbox conservata. Implementare/usare handoff LFS prima della distruzione." }
        45 { throw "Submodule non supportati dal bundle del parent, anche se puliti. Sandbox conservata." }
        46 { throw "Ispezione Git/LFS fallita. Sandbox conservata." }
    }
    if ($Guard.Code -ne 0) {
        throw "Controlli pre-handoff Git falliti (exit $($Guard.Code)). Sandbox conservata. Output: $($Guard.Text)"
    }

    $SnapshotCommand = @"
set -eu
git add -A
if ! git diff --cached --quiet; then
  git -c core.hooksPath=/dev/null -c user.name='OCBox Snapshot' -c user.email='snapshot@localhost' commit --no-gpg-sign -m '$Message' >/dev/null
fi
git update-ref 'refs/heads/$SnapshotBranch' HEAD
git show-ref --verify --quiet 'refs/heads/$SnapshotBranch'
"@

    $Result = Invoke-SandboxShellCapture -SandboxName $SandboxName -Command $SnapshotCommand
    if ($Result.Code -ne 0) {
        throw "Snapshot Git nella sandbox fallito (exit $($Result.Code)). Sandbox conservata. Output: $($Result.Text)"
    }

    return [pscustomobject]@{
        Branch = $SnapshotBranch
        IgnoredCount = 0
    }
}

function Export-SandboxGitHandoff {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectPath,
        [Parameter(Mandatory = $true)][string]$SandboxName,
        [Parameter(Mandatory = $true)][string]$SessionId,
        [Parameter(Mandatory = $true)]$Snapshot,
        [ValidateSet("opencode", "shell")][string]$Agent = "opencode"
    )

    $null = Assert-ManagedSandbox -SandboxName $SandboxName -ProjectPath $ProjectPath -Agent $Agent
    $RemoteName = "sandbox-$SandboxName"
    $RefRoot = "refs/ocbox/$SessionId"
    $SnapshotRef = "$RefRoot/snapshot"
    $BundleInSandbox = "/tmp/ocbox-handoff-$SessionId.bundle"
    $BundleHost = Join-Path ([IO.Path]::GetTempPath()) "ocbox-handoff-$SessionId.bundle"

    # Everything Git parses from the sandbox is untrusted. Disable host hooks and
    # automatic maintenance for every handoff Git invocation. This limits the host
    # side effect surface to object/ref parsing and passive refs/ocbox/* updates.
    $SafeGitConfig = @("-c", "core.hooksPath=NUL", "-c", "maintenance.auto=false", "-c", "gc.auto=0")

    $HostHeadBefore = (& git @SafeGitConfig -C $ProjectPath rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0) { throw "Impossibile leggere HEAD del repository host." }
    $HostStatusBefore = (@(& git @SafeGitConfig -C $ProjectPath status --porcelain=v1 2>$null) -join "`n")
    if ($LASTEXITCODE -ne 0) { throw "Impossibile leggere lo stato del repository host." }

    Remove-Item -LiteralPath $BundleHost -Force -ErrorAction SilentlyContinue

    try {
        $BundleCommand = @"
set -eu
rm -f '$BundleInSandbox'
git -c core.hooksPath=/dev/null -c maintenance.auto=false -c gc.auto=0 bundle create '$BundleInSandbox' --branches
test -s '$BundleInSandbox'
"@
        $BundleResult = Invoke-SandboxShellCapture -SandboxName $SandboxName -Command $BundleCommand
        if ($BundleResult.Code -ne 0) {
            throw "Creazione Git bundle nella sandbox fallita (exit $($BundleResult.Code)). Sandbox conservata. Output: $($BundleResult.Text)"
        }

        $Previous = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            $CopyOutput = @(& sbx cp "${SandboxName}:${BundleInSandbox}" $BundleHost 2>&1)
            $CopyCode = $LASTEXITCODE
        }
        finally { $ErrorActionPreference = $Previous }
        if ($CopyCode -ne 0 -or -not (Test-Path -LiteralPath $BundleHost -PathType Leaf)) {
            throw "Copia Git bundle sandbox -> host fallita. Sandbox conservata. Output: $($CopyOutput -join ' ')"
        }

        $BundleLength = (Get-Item -LiteralPath $BundleHost).Length
        if ($BundleLength -le 0) {
            throw "Git bundle vuoto. Sandbox conservata."
        }

        $Previous = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            $VerifyOutput = @(& git @SafeGitConfig -C $ProjectPath bundle verify $BundleHost 2>&1)
            $VerifyCode = $LASTEXITCODE
        }
        finally { $ErrorActionPreference = $Previous }
        if ($VerifyCode -ne 0) {
            throw "Verifica Git bundle sul host fallita. Sandbox conservata. Output: $($VerifyOutput -join ' ')"
        }

        $BranchRefspec = "+refs/heads/*:$RefRoot/heads/*"
        $Previous = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            $FetchOutput = @(& git @SafeGitConfig -C $ProjectPath fetch --no-tags --force $BundleHost $BranchRefspec 2>&1)
            $FetchCode = $LASTEXITCODE
        }
        finally { $ErrorActionPreference = $Previous }
        if ($FetchCode -ne 0) {
            throw "Import handoff dal Git bundle fallito. Sandbox conservata. Output: $($FetchOutput -join ' ')"
        }

        $FetchedSnapshotSource = "$RefRoot/heads/$($Snapshot.Branch)"
        $Previous = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            $FetchedShaOutput = @(& git @SafeGitConfig -C $ProjectPath rev-parse --verify "$FetchedSnapshotSource^{commit}" 2>&1)
            $FetchedShaCode = $LASTEXITCODE
        }
        finally { $ErrorActionPreference = $Previous }
        if ($FetchedShaCode -ne 0 -or $FetchedShaOutput.Count -eq 0) {
            throw "Il branch snapshot non e stato importato/verificato dal host: $FetchedSnapshotSource. Sandbox conservata."
        }
        $FetchedSha = "$($FetchedShaOutput[-1])".Trim().ToLowerInvariant()
        if ($FetchedSha -notmatch '^[0-9a-f]{40,64}$') {
            throw "SHA handoff non valida per $($FetchedSnapshotSource): $FetchedSha. Sandbox conservata."
        }

        & git @SafeGitConfig -C $ProjectPath update-ref $SnapshotRef $FetchedSha
        if ($LASTEXITCODE -ne 0) {
            throw "Impossibile creare il ref passivo $SnapshotRef. Sandbox conservata."
        }

        $HostHeadAfter = (& git @SafeGitConfig -C $ProjectPath rev-parse HEAD).Trim()
        if ($LASTEXITCODE -ne 0) { throw "Cannot verify host HEAD after handoff. Sandbox preserved." }
        $HostStatusAfter = (@(& git @SafeGitConfig -C $ProjectPath status --porcelain=v1 2>$null) -join "`n")
        if ($LASTEXITCODE -ne 0) { throw "Cannot verify host status after handoff. Sandbox preserved." }
        if ($HostHeadAfter -ne $HostHeadBefore -or $HostStatusAfter -ne $HostStatusBefore) {
            throw "Il working tree host e cambiato durante l'handoff. Sandbox conservata per analisi."
        }

        return [pscustomobject]@{
            Agent = $Agent
            SandboxName = $SandboxName
            ProjectPath = $ProjectPath
            SessionId = $SessionId
            RefRoot = $RefRoot
            SnapshotRef = $SnapshotRef
            SnapshotSha = $FetchedSha
            RemoteName = $RemoteName
            IgnoredCount = $Snapshot.IgnoredCount
            HostHead = $HostHeadBefore
            BundleBytes = $BundleLength
            Transport = "git-bundle"
        }
    }
    finally {
        Remove-Item -LiteralPath $BundleHost -Force -ErrorAction SilentlyContinue
    }
}

function Remove-SandboxAfterHandoff {
    param(
        [Parameter(Mandatory = $true)][string]$SandboxName,
        [Parameter(Mandatory = $true)][string]$ProjectPath,
        [Parameter(Mandatory = $true)]$Handoff
    )

    if ($Handoff.SandboxName -cne $SandboxName -or $Handoff.ProjectPath -cne $ProjectPath -or
        $Handoff.SnapshotRef -cne "refs/ocbox/$($Handoff.SessionId)/snapshot" -or
        $Handoff.SnapshotSha -notmatch '^[0-9a-f]{40,64}$') {
        throw "Handoff identity is invalid. Sandbox preserved."
    }
    $null = Assert-ManagedSandbox -SandboxName $SandboxName -ProjectPath $ProjectPath -Agent $Handoff.Agent
    $SafeGitConfig = @("-c", "core.hooksPath=NUL", "-c", "maintenance.auto=false", "-c", "gc.auto=0")
    $PreservedBeforeRemoval = @(& git @SafeGitConfig -C $ProjectPath rev-parse --verify "$($Handoff.SnapshotRef)^{commit}")
    if ($LASTEXITCODE -ne 0 -or $PreservedBeforeRemoval.Count -ne 1 -or
        "$($PreservedBeforeRemoval[0])".Trim() -cne $Handoff.SnapshotSha) {
        throw "Passive handoff ref changed or is missing. Sandbox preserved."
    }

    $Previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $Output = @(& sbx rm --force $SandboxName 2>&1)
        $Code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $Previous }
    if ($Code -ne 0) {
        throw "Handoff salvato in $($Handoff.SnapshotRef), ma sbx rm e fallito. Output: $($Output -join ' ')"
    }
    if (@(Get-SandboxNames) -contains $SandboxName) {
        throw "Sandbox still exists after removal. Ownership receipt retained; handoff is in $($Handoff.SnapshotRef)."
    }

    Remove-Item -LiteralPath (Get-SandboxOwnershipPath -SandboxName $SandboxName) -Force

    $Previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & git @SafeGitConfig -C $ProjectPath remote get-url $Handoff.RemoteName 1>$null 2>$null
        $RemoteStillExists = ($LASTEXITCODE -eq 0)
    }
    finally { $ErrorActionPreference = $Previous }

    if ($RemoteStillExists) {
        & git @SafeGitConfig -C $ProjectPath remote remove $Handoff.RemoteName
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Sandbox rimossa ma remote Git stale non eliminato: $($Handoff.RemoteName)"
        }
    }

    $Preserved = (& git @SafeGitConfig -C $ProjectPath rev-parse $Handoff.SnapshotRef).Trim()
    if ($LASTEXITCODE -ne 0 -or $Preserved.ToLowerInvariant() -ne $Handoff.SnapshotSha) {
        throw "Sandbox rimossa ma il ref handoff non e verificabile: $($Handoff.SnapshotRef)"
    }
}
