Set-StrictMode -Version 3.0

function Invoke-SandboxShellCapture {
    param(
        [Parameter(Mandatory = $true)][string]$SandboxName,
        [Parameter(Mandatory = $true)][string]$Command
    )

    # Normalize exactly at the Windows -> Linux boundary. PowerShell files are
    # commonly CRLF on Windows, while the sandbox shell expects LF.
    $LinuxCommand = $Command.Replace("`r`n", "`n").Replace("`r", "")

    $Previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $Output = @(& sbx run shell --name $SandboxName -- -c $LinuxCommand 2>&1)
        $Code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $Previous
    }

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

    # Keep the sandbox as the only place where project code is executed. The host
    # will not trust text emitted by this command; it will independently fetch and
    # resolve the deterministic snapshot ref afterwards.
    #
    # Refuse automatic destruction when ignored files exist. `git add -A` cannot
    # preserve them, and an ignored file may still be valuable agent output.
    $Command = @"
set -eu
git rev-parse --is-inside-work-tree >/dev/null
git ls-files --others -i --exclude-standard > '$IgnoredList'
if [ -s '$IgnoredList' ]; then
  printf '%s\n' 'OCBOXIGNOREDFILES'
  cat '$IgnoredList'
  exit 42
fi
git add -A
if ! git diff --cached --quiet; then
  git -c core.hooksPath=/dev/null -c user.name='OCBox Snapshot' -c user.email='snapshot@localhost' commit --no-gpg-sign -m '$Message' >/dev/null
fi
git update-ref 'refs/heads/$SnapshotBranch' HEAD
git show-ref --verify --quiet 'refs/heads/$SnapshotBranch'
"@

    $Result = Invoke-SandboxShellCapture -SandboxName $SandboxName -Command $Command
    if ($Result.Code -eq 42) {
        throw "La sandbox contiene file gitignored non preservabili automaticamente. Sandbox conservata. Output: $($Result.Text)"
    }
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

    $HostHeadBefore = (& git -C $ProjectPath rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0) { throw "Impossibile leggere HEAD del repository host." }
    $HostStatusBefore = (@(& git -C $ProjectPath status --porcelain=v1 2>$null) -join "`n")
    if ($LASTEXITCODE -ne 0) { throw "Impossibile leggere lo stato del repository host." }

    $Previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $RemoteUrl = @(& git -C $ProjectPath remote get-url $RemoteName 2>&1)
        $RemoteCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $Previous
    }
    if ($RemoteCode -ne 0) {
        throw "Remote $RemoteName non disponibile. Non distruggo la sandbox. Output: $($RemoteUrl -join ' ')"
    }

    # Fetch every advertised branch into a passive namespace. No checkout, merge,
    # rebase, hook, package script or project code is executed on the host.
    $BranchRefspec = "+refs/heads/*:$RefRoot/heads/*"
    $Previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $FetchOutput = @(& git -C $ProjectPath fetch --no-tags --force $RemoteName $BranchRefspec 2>&1)
        $FetchCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $Previous
    }
    if ($FetchCode -ne 0) {
        throw "Fetch handoff fallito. Non distruggo la sandbox. Output: $($FetchOutput -join ' ')"
    }

    # The host independently resolves the deterministic snapshot branch. Do not
    # trust a SHA printed by the compromised sandbox.
    $FetchedSnapshotSource = "$RefRoot/heads/$($Snapshot.Branch)"
    $Previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $FetchedShaOutput = @(& git -C $ProjectPath rev-parse --verify "$FetchedSnapshotSource^{commit}" 2>&1)
        $FetchedShaCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $Previous
    }
    if ($FetchedShaCode -ne 0 -or $FetchedShaOutput.Count -eq 0) {
        throw "Il branch snapshot non e stato ricevuto/verificato dal host: $FetchedSnapshotSource. Sandbox conservata."
    }
    $FetchedSha = "$($FetchedShaOutput[-1])".Trim().ToLowerInvariant()
    if ($FetchedSha -notmatch '^[0-9a-f]{40,64}$') {
        throw "SHA fetch non valida per $FetchedSnapshotSource: $FetchedSha. Sandbox conservata."
    }

    & git -C $ProjectPath update-ref $SnapshotRef $FetchedSha
    if ($LASTEXITCODE -ne 0) {
        throw "Impossibile creare il ref passivo $SnapshotRef. Sandbox conservata."
    }

    $HostHeadAfter = (& git -C $ProjectPath rev-parse HEAD).Trim()
    $HostStatusAfter = (@(& git -C $ProjectPath status --porcelain=v1 2>$null) -join "`n")
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
    finally {
        $ErrorActionPreference = $Previous
    }
    if ($Code -ne 0) {
        throw "Handoff salvato in $($Handoff.SnapshotRef), ma sbx rm e fallito. Output: $($Output -join ' ')"
    }

    # Docker normally removes sandbox-<name> automatically. If a stale remote
    # remains, remove only that remote; never touch branches or the working tree.
    $Previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & git -C $ProjectPath remote get-url $Handoff.RemoteName 1>$null 2>$null
        $RemoteStillExists = ($LASTEXITCODE -eq 0)
    }
    finally {
        $ErrorActionPreference = $Previous
    }
    if ($RemoteStillExists) {
        & git -C $ProjectPath remote remove $Handoff.RemoteName
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Sandbox rimossa ma remote Git stale non eliminato: $($Handoff.RemoteName)"
        }
    }

    $Preserved = (& git -C $ProjectPath rev-parse $Handoff.SnapshotRef).Trim()
    if ($LASTEXITCODE -ne 0 -or $Preserved.ToLowerInvariant() -ne $Handoff.SnapshotSha) {
        throw "Sandbox rimossa ma il ref handoff non e verificabile: $($Handoff.SnapshotRef)"
    }
}
