[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$ProjectPath,

    [string]$SandboxName,
    [switch]$NoAttach,
    [switch]$NoAutoStartServer
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "private\Common.ps1")
. (Join-Path $PSScriptRoot "private\GitHandoff.ps1")

$CallerLocation = (Get-Location).Path
$Config = Get-ToolConfig
Assert-Command "sbx"

$ProjectPath = Resolve-ProjectDirectory -ProjectPath $ProjectPath
if ($Config.UseCloneMode) {
    Assert-GitRepository -ProjectPath $ProjectPath
}

if ([string]::IsNullOrWhiteSpace($SandboxName)) {
    $SandboxName = Get-ProjectSandboxName -ProjectPath $ProjectPath -Prefix $Config.SandboxPrefix
    if ($Config.UseCloneMode) {
        $SandboxName = "$SandboxName-clone"
    }
}

$ServerLauncher = $null
$ServerWasAlreadyRunning = Test-LlamaApi -Port ([int]$Config.LlamaPort)
$SavedSshAuthSock = $env:SSH_AUTH_SOCK

if ($Config.DisableSshAgentForwarding) {
    Remove-Item Env:SSH_AUTH_SOCK -ErrorAction SilentlyContinue
}

try {
    if (-not $ServerWasAlreadyRunning) {
        if ($NoAutoStartServer) {
            Write-Warning "llama-server non risponde. Avvialo con: .\sandbox.ps1 server"
        }
        else {
            $ServerLauncher = Start-LlamaWindowAndWait -Config $Config
        }
    }

    $Existing = @(Get-SandboxNames)
    if ($Existing -notcontains $SandboxName) {
        Write-Host "Creazione sandbox hardened $SandboxName..." -ForegroundColor Cyan
        Write-Host "Host repo read-only; lavoro in clone privato della microVM." -ForegroundColor DarkGray

        $CreateArgs = @(
            "create",
            "--name", $SandboxName,
            "--memory", $Config.SandboxMemory,
            "--cpus", "$($Config.SandboxCpus)"
        )
        if ($Config.UseCloneMode) {
            $CreateArgs += "--clone"
        }
        if ($Config.DisableSharedSkills) {
            $CreateArgs += "--no-share-skills"
        }
        $CreateArgs += @("opencode", $ProjectPath)

        $CreateStarted = Get-Date
        Invoke-External "sbx" $CreateArgs
        $Elapsed = (Get-Date) - $CreateStarted
        Write-Host ("Sandbox creata in {0:n1}s." -f $Elapsed.TotalSeconds) -ForegroundColor Green
    }
    else {
        Write-Host "Sandbox esistente: $SandboxName" -ForegroundColor Yellow
    }

    Write-Host "Applico public-web 80/443, endpoint llama isolato e configurazione OpenCode no-approval..." -ForegroundColor Cyan
    Install-SandboxConfiguration -Config $Config -SandboxName $SandboxName

    Write-Host ""
    Write-Host "Progetto host: $ProjectPath" -ForegroundColor Green
    Write-Host "Sandbox: $SandboxName" -ForegroundColor Green
    if ($Config.UseCloneMode) {
        Write-Host "Modalita: CLONE - repo host read-only; modifiche nella copia privata." -ForegroundColor Green
    }
    if ($Config.AllowFullWeb) {
        Write-Host "Rete: HTTP/HTTPS pubblico su 80/443; LAN/private e servizi host non autorizzati bloccati." -ForegroundColor Green
    }
    Write-Host "OpenCode: nessun approval prompt dentro la microVM." -ForegroundColor Green
    if ($Config.DestroyWorkSandboxOnExit) {
        Write-Host "Lifecycle: snapshot Git -> bundle verificato -> refs/ocbox/* -> distruzione microVM." -ForegroundColor Green
    }
    else {
        Write-Host "Lifecycle: sandbox mantenuta dopo l'uscita." -ForegroundColor Yellow
    }
    Write-Host ""

    if (-not $NoAttach) {
        Set-Location -LiteralPath $ProjectPath
        & sbx run --name $SandboxName
        if ($LASTEXITCODE -ne 0) {
            throw "OpenCode/sbx terminato con exit code $LASTEXITCODE."
        }

        if ($Config.DestroyWorkSandboxOnExit) {
            if (-not $Config.UseCloneMode) {
                throw "Distruzione automatica richiede clone mode. Sandbox conservata."
            }

            $HostHeadBeforeHandoff = (& git -C $ProjectPath rev-parse HEAD).Trim().ToLowerInvariant()
            if ($LASTEXITCODE -ne 0) {
                throw "Impossibile leggere HEAD host prima dell'handoff. Sandbox conservata."
            }

            $SessionId = Get-HandoffSessionId
            Write-Host "Preservo il lavoro prima di distruggere la microVM..." -ForegroundColor Cyan
            $Snapshot = New-SandboxGitSnapshot -SandboxName $SandboxName -SessionId $SessionId

            if ($Snapshot.IgnoredCount -gt 0) {
                Write-Warning "Trovati $($Snapshot.IgnoredCount) file ignored/untracked nel clone. Il Git handoff non li include: sandbox conservata per evitare perdita dati."
            }
            else {
                $Handoff = Export-SandboxGitHandoff -ProjectPath $ProjectPath -SandboxName $SandboxName -SessionId $SessionId -Snapshot $Snapshot
                $HasChanges = ($Handoff.SnapshotSha -ne $HostHeadBeforeHandoff)

                if ($HasChanges) {
                    Write-Host "Snapshot con modifiche verificato sul host: $($Handoff.SnapshotRef)" -ForegroundColor Green
                    Write-Host "SHA: $($Handoff.SnapshotSha)" -ForegroundColor DarkGray
                }
                else {
                    Write-Host "Nessuna modifica prodotta dall'agente in questa sessione." -ForegroundColor Yellow
                    Write-Host "Snapshot verificato: $($Handoff.SnapshotRef)" -ForegroundColor DarkGray
                }

                Remove-SandboxAfterHandoff -SandboxName $SandboxName -ProjectPath $ProjectPath -Handoff $Handoff
                Write-Host "MicroVM distrutta. Il working tree host non e stato modificato." -ForegroundColor Green
                if ($HasChanges) {
                    Write-Host "Review sicura: .\sandbox.ps1 review `"$ProjectPath`"" -ForegroundColor Cyan
                }
            }
        }
    }
}
finally {
    if (Test-Path -LiteralPath $CallerLocation -PathType Container) {
        Set-Location -LiteralPath $CallerLocation
    }

    if ($Config.DisableSshAgentForwarding -and $null -ne $SavedSshAuthSock) {
        $env:SSH_AUTH_SOCK = $SavedSshAuthSock
    }

    if ($null -ne $ServerLauncher) {
        Stop-LlamaProcessTree -ProcessId ([int]$ServerLauncher.ProcessId) -Port ([int]$ServerLauncher.Port)
    }
}
