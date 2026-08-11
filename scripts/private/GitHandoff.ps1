Set-StrictMode -Version 3.0

function Invoke-SandboxShellCapture {
    param(
        [Parameter(Mandatory = $true)][string]$SandboxName,
        [Parameter(Mandatory = $true)][string]$Command
    )

    # PowerShell scripts are commonly checked out with CRLF on Windows. Passing a
    # multiline string verbatim to the Linux shell leaves the carriage return
    # attached to tokens such as `set -eu\r` or `git add -A\r`. Normalize exactly
    # at the Windows -> Linux boundary so every handoff command is shell-safe.
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

    # The sandbox may be fully compromised. This command is allowed to execute there;
    # the host trusts only the Git objects it later fetches as passive refs. Disable
    # commit hooks/signing so a project hook cannot block the preservation step.
    #
    # Deliberately avoid shell command substitution ($(...)) here. The command crosses
    # PowerShell -> sbx -> Linux shell, and nested substitution/quoting is unnecessary
    # for this protocol. Emit marker lines followed by plain command output instead.
    $Command = @"
set -eu
git rev-parse --is-inside-work-tree >/dev/null
git add -A
if ! git diff --cached --quiet; then
  git -c core.hooksPath=/dev/null -c user.name='OCBox Snapshot' -c user.email='snapshot@localhost' commit --no-gpg-sign -m '$Message' >/dev/null
fi
git update-ref 'refs/heads/$SnapshotBranch' HEAD
printf '%s\n' 'SNAPSHOT_SHA'
git rev-parse HEAD
printf '%s\n' 'SNAPSHOT_BRANCH'
printf '%s\n' '$SnapshotBranch'
printf '%s\n' 'IGNORED_COUNT'
git ls-files --others -i --exclude-standard | wc -l | tr -d ' '
printf '\n'
"@

    $Result = Invoke-SandboxShellCapture -SandboxName $SandboxName -Command $Command
    if ($Result.Code -ne 0) {
        throw "Snapshot Git nella sandbox fallito (exit $($Result.Code)). Sandbox conservata. Output: $($Result.Text)"
    }

    $ShaMatch = [regex]::Match($Result.Text, '(?m)^SNAPSHOT_SHA\n([0-9a-fA-F]{40,64})$')
    $BranchMatch = [regex]::Match($Result.Text, '(?m)^SNAPSHOT_BRANCH\n([^\r\n]+)$')
    $IgnoredMatch = [regex]::Match($Result.Text, '(?m)^IGNORED_COUNT\n([0-9]+)$')
    if (-not $ShaMatch.Success -or -not $BranchMatch.Success -or -not $IgnoredMatch.Success) {
        throw "Impossibile verificare lo snapshot Git prodotto dalla sandbox. Sandbox conservata. Output: $($Result.Text)"
    }

    return [pscustomobject]@{
        Sha = $ShaMatch.Groups[1].Value.ToLowerInvariant()
        Branch = $BranchMatch.Groups[1].Value
        IgnoredCount = [int]$IgnoredMatch.Groups[1].Value
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

    # Fetch every advertised branch into a private passive namespace. This never
    # checks out, merges, rebases, runs project code, or changes the host working tree.
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

    $FetchedSnapshotSource = "$RefRoot/heads/$($Snapshot.Branch)"
    $FetchedSha = (& git -C $ProjectPath rev-parse $FetchedSnapshotSource).Trim()
    if ($LASTEXITCODE -ne 0 -or $FetchedSha.ToLowerInvariant() -ne $Snapshot.Sha) {
        throw "Verifica SHA handoff fallita. Atteso $($Snapshot.Sha), ottenuto $FetchedSha. Sandbox conservata."
    }

    & git -C $ProjectPath update-ref $SnapshotRef $Snapshot.Sha
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
        SnapshotSha = $Snapshot.Sha
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
