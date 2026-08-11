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
    $IgnoredList = "/tmp/ocbox-ignored-$SessionId.txt"

    # Conservative preservation gate. These cases need dedicated transport logic:
    # - ignored files are outside ordinary Git history;
    # - multiple worktrees can contain independent uncommitted state;
    # - Git LFS objects are not embedded in a normal Git bundle;
    # - dirty submodules contain nested repository state not captured by the parent.
    $GuardCommand = @"
set -eu
git rev-parse --is-inside-work-tree >/dev/null
WORKTREE_COUNT=`$(git worktree list --porcelain | grep -c '^worktree ' || true)
if [ "`$WORKTREE_COUNT" -gt 1 ]; then
  printf '%s\n' 'OCBOX_MULTIPLE_WORKTREES'
  git worktree list --porcelain
  exit 43
fi
if command -v git-lfs >/dev/null 2>&1 || git lfs version >/dev/null 2>&1; then
  if git lfs ls-files 2>/dev/null | grep -q .; then
    printf '%s\n' 'OCBOX_GIT_LFS_TRACKED'
    exit 44
  fi
fi
if [ -f .gitmodules ]; then
  if ! git submodule foreach --quiet --recursive 'git diff --quiet && git diff --cached --quiet && test -z "`$(git ls-files --others --exclude-standard)"'; then
    printf '%s\n' 'OCBOX_DIRTY_SUBMODULE'
    exit 45
  fi
fi
git ls-files --others -i --exclude-standard > '$IgnoredList'
if [ -s '$IgnoredList' ]; then
  printf '%s\n' 'OCBOX_IGNOREDFILES'
  cat '$IgnoredList'
  exit 42
fi
"@

    $Guard = Invoke-SandboxShellCapture -SandboxName $SandboxName -Command $GuardCommand
    switch ($Guard.Code) {
        42 { throw "La sandbox contiene file gitignored non preservabili automaticamente. Sandbox conservata. Output: $($Guard.Text)" }
        43 { throw "La sandbox contiene worktree Git secondari. Handoff automatico non sicuro: sandbox conservata. Output: $($Guard.Text)" }
        44 { throw "Il repository usa Git LFS. Un Git bundle non preserva gli oggetti LFS: sandbox conservata. Implementare/usarе handoff LFS prima della distruzione." }
        45 { throw "Sono presenti modifiche non committate dentro un submodule. Sandbox conservata per evitare perdita dati." }
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
        [Parameter(Mandatory = $true)]$Snapshot
    )

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
        $HostStatusAfter = (@(& git @SafeGitConfig -C $ProjectPath status --porcelain=v1 2>$null) -join "`n")
        if ($HostHeadAfter -ne $HostHeadBefore -or $HostStatusAfter -ne $HostStatusBefore) {
            throw "Il working tree host e cambiato durante l'handoff. Sandbox conservata per analisi."
        }

        return [pscustomobject]@{
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

    $SafeGitConfig = @("-c", "core.hooksPath=NUL", "-c", "maintenance.auto=false", "-c", "gc.auto=0")

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
