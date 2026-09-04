[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$ProjectPath,

    [string]$SandboxName,
    [switch]$NoAttach,
    [switch]$NoAutoStartServer,
    [switch]$DemoMode
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
            Write-Warning "llama-server is not responding. Start it with: .\sandbox.ps1 server"
        }
        else {
            $ServerLauncher = Start-LlamaWindowAndWait -Config $Config
        }
    }

    $Existing = @(Get-SandboxNames)
    if ($Existing -notcontains $SandboxName) {
        if ($DemoMode) {
            Write-Host "Creating disposable Docker Sandbox microVM..." -ForegroundColor Cyan
            Write-Host "  Host checkout: read-only" -ForegroundColor DarkGray
            Write-Host "  Agent workspace: private Git clone" -ForegroundColor DarkGray
        }
        else {
            Write-Host "Creating hardened sandbox $SandboxName..." -ForegroundColor Cyan
            Write-Host "Host repository is read-only; agent work happens in a private microVM clone." -ForegroundColor DarkGray
        }

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
        if ($DemoMode) {
            $Previous = $ErrorActionPreference
            try {
                $ErrorActionPreference = "Continue"
                $CreateOutput = @(& sbx @CreateArgs 2>&1)
                $CreateCode = $LASTEXITCODE
            }
            finally {
                $ErrorActionPreference = $Previous
            }
            if ($CreateCode -ne 0) {
                throw "Sandbox creation failed (exit $CreateCode): $((($CreateOutput | ForEach-Object { \"$($_)\" }) -join \"`n\").Trim())"
            }
        }
        else {
            Invoke-External "sbx" $CreateArgs
        }
        $Elapsed = (Get-Date) - $CreateStarted
        Write-Host ("Sandbox ready in {0:n1}s." -f $Elapsed.TotalSeconds) -ForegroundColor Green
    }
    else {
        if ($DemoMode) {
            Write-Host "Disposable sandbox ready." -ForegroundColor Green
        }
        else {
            Write-Host "Existing sandbox: $SandboxName" -ForegroundColor Yellow
        }
    }

    if (-not $DemoMode) {
        Write-Host "Applying public-web 80/443 policy, isolated llama endpoint, and no-approval OpenCode config..." -ForegroundColor Cyan
    }
    Install-SandboxConfiguration -Config $Config -SandboxName $SandboxName

    Write-Host ""
    if ($DemoMode) {
        Write-Host "SANDBOX READY" -ForegroundColor Green
        Write-Host "  OpenCode: full permissions inside the microVM" -ForegroundColor Green
        Write-Host "  Public web: allowed on 80/443" -ForegroundColor Green
        Write-Host "  Host/LAN/credentials: outside the default trust boundary" -ForegroundColor Green
        Write-Host ""
    }
    else {
        Write-Host "Host project: $ProjectPath" -ForegroundColor Green
        Write-Host "Sandbox: $SandboxName" -ForegroundColor Green
        if ($Config.UseCloneMode) {
            Write-Host "Mode: CLONE - host repository read-only; changes stay in the private clone." -ForegroundColor Green
        }
        if ($Config.AllowFullWeb) {
            Write-Host "Network: public HTTP/HTTPS on 80/443; private/LAN and unauthorized host services denied." -ForegroundColor Green
        }
        Write-Host "OpenCode: no approval prompts inside the microVM." -ForegroundColor Green
        if ($Config.DestroyWorkSandboxOnExit) {
            Write-Host "Lifecycle: Git snapshot -> verified bundle -> refs/ocbox/* -> destroy microVM." -ForegroundColor Green
        }
        else {
            Write-Host "Lifecycle: sandbox is preserved after exit." -ForegroundColor Yellow
        }
        Write-Host ""
    }

    if (-not $NoAttach) {
        Set-Location -LiteralPath $ProjectPath
        & sbx run --name $SandboxName
        if ($LASTEXITCODE -ne 0) {
            throw "OpenCode/sbx exited with code $LASTEXITCODE."
        }

        if ($Config.DestroyWorkSandboxOnExit) {
            if (-not $Config.UseCloneMode) {
                throw "Automatic destruction requires clone mode. Sandbox preserved."
            }

            $HostHeadBeforeHandoff = (& git -C $ProjectPath rev-parse HEAD).Trim().ToLowerInvariant()
            if ($LASTEXITCODE -ne 0) {
                throw "Could not read host HEAD before handoff. Sandbox preserved."
            }

            $SessionId = Get-HandoffSessionId
            if ($DemoMode) {
                Write-Host ""
                Write-Host "AGENT EXITED - VERIFYING GIT-ONLY HANDOFF" -ForegroundColor Cyan
            }
            else {
                Write-Host "Preserving agent work before destroying the microVM..." -ForegroundColor Cyan
            }
            $Snapshot = New-SandboxGitSnapshot -SandboxName $SandboxName -SessionId $SessionId

            if ($Snapshot.IgnoredCount -gt 0) {
                Write-Warning "Found $($Snapshot.IgnoredCount) ignored/untracked files that Git handoff cannot preserve automatically. Sandbox kept alive to avoid data loss."
            }
            else {
                $Handoff = Export-SandboxGitHandoff -ProjectPath $ProjectPath -SandboxName $SandboxName -SessionId $SessionId -Snapshot $Snapshot
                $HasChanges = ($Handoff.SnapshotSha -ne $HostHeadBeforeHandoff)

                if ($HasChanges) {
                    if ($DemoMode) {
                        Write-Host "  PASS  Snapshot exported as a verified Git bundle" -ForegroundColor Green
                        Write-Host "  PASS  Imported only into passive $($Handoff.SnapshotRef)" -ForegroundColor Green
                    }
                    else {
                        Write-Host "Verified changed snapshot on host: $($Handoff.SnapshotRef)" -ForegroundColor Green
                        Write-Host "SHA: $($Handoff.SnapshotSha)" -ForegroundColor DarkGray
                    }
                }
                else {
                    Write-Host "No agent changes were produced in this session." -ForegroundColor Yellow
                    Write-Host "Verified snapshot: $($Handoff.SnapshotRef)" -ForegroundColor DarkGray
                }

                Remove-SandboxAfterHandoff -SandboxName $SandboxName -ProjectPath $ProjectPath -Handoff $Handoff
                if ($DemoMode) {
                    Write-Host "  PASS  Disposable microVM destroyed" -ForegroundColor Green
                    Write-Host "  PASS  Host checkout was never modified" -ForegroundColor Green
                }
                else {
                    Write-Host "MicroVM destroyed. Host working tree was not modified." -ForegroundColor Green
                    if ($HasChanges) {
                        Write-Host "Safe review: .\sandbox.ps1 review `"$ProjectPath`"" -ForegroundColor Cyan
                    }
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
