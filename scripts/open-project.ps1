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

    Write-Host "Applico full-web, endpoint llama isolato e configurazione OpenCode no-approval..." -ForegroundColor Cyan
    Install-SandboxConfiguration -Config $Config -SandboxName $SandboxName

    Write-Host ""
    Write-Host "Progetto host: $ProjectPath" -ForegroundColor Green
    Write-Host "Sandbox: $SandboxName" -ForegroundColor Green
    if ($Config.UseCloneMode) {
        Write-Host "Modalita: CLONE - repo host read-only; modifiche nella copia privata." -ForegroundColor Green
    }
    if ($Config.AllowFullWeb) {
        Write-Host "Rete: Internet HTTP/HTTPS completo; host/LAN/private ranges restano isolati da Docker." -ForegroundColor Green
    }
    Write-Host "OpenCode: nessun approval prompt dentro la microVM." -ForegroundColor Green
    Write-Host ""

    if (-not $NoAttach) {
        Set-Location -LiteralPath $ProjectPath
        & sbx run --name $SandboxName
        if ($LASTEXITCODE -ne 0) {
            throw "OpenCode/sbx terminato con exit code $LASTEXITCODE."
        }
    }

    if ($Config.DestroyWorkSandboxOnExit) {
        Write-Warning "Distruzione automatica richiesta, ma prima va completato il workflow Git di handoff sicuro."
    }
}
finally {
    if ($Config.DisableSshAgentForwarding -and $null -ne $SavedSshAuthSock) {
        $env:SSH_AUTH_SOCK = $SavedSshAuthSock
    }

    if ($null -ne $ServerLauncher) {
        Stop-LlamaProcessTree -ProcessId ([int]$ServerLauncher.ProcessId) -Port ([int]$ServerLauncher.Port)
    }
}
