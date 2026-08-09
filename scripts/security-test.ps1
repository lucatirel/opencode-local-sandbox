[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "private\Common.ps1")

Assert-Command "sbx"
Assert-Command "git"

function Add-Result {
    param([string]$Name, [bool]$Passed, [string]$Detail)
    $script:Results.Add([pscustomobject]@{
        Result = if ($Passed) { "PASS" } else { "FAIL" }
        Check  = $Name
        Detail = $Detail
    })
}

function Invoke-SbxCapture {
    param(
        [Parameter(Mandatory = $true)][string]$Sandbox,
        [Parameter(Mandatory = $true)][string[]]$CommandArgs
    )

    $Previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $Output = @(& sbx exec $Sandbox @CommandArgs 2>&1)
        $Code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $Previous
    }

    $Text = (($Output | ForEach-Object { "$($_)" }) -join "`n").Trim()
    return [pscustomobject]@{
        ExitCode = $Code
        Text     = $Text
    }
}

function Invoke-SbxRunShellCapture {
    param(
        [Parameter(Mandatory = $true)][string]$Sandbox,
        [Parameter(Mandatory = $true)][string]$Command
    )

    $Previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $Output = @(& sbx run shell --name $Sandbox -- -c $Command 2>&1)
        $Code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $Previous
    }

    $Text = (($Output | ForEach-Object { "$($_)" }) -join "`n").Trim()
    return [pscustomobject]@{
        ExitCode = $Code
        Text     = $Text
    }
}

function Get-WindowsPathCandidates {
    param([Parameter(Mandatory = $true)][string]$WindowsPath)

    $Full = [IO.Path]::GetFullPath($WindowsPath)
    if ($Full -match '^([A-Za-z]):\\(.*)$') {
        $Drive = $Matches[1].ToLowerInvariant()
        $Rest = $Matches[2].Replace('\','/')
        return @(
            "/$Drive/$Rest",
            "/mnt/$Drive/$Rest"
        )
    }
    return @($Full.Replace('\','/'))
}

$Results = New-Object System.Collections.Generic.List[object]
$Nonce = [Guid]::NewGuid().ToString("N").Substring(0, 8)
$SandboxName = "oc-security-$Nonce"
$Root = Join-Path $env:TEMP "ocbox-security-$Nonce"
$Repo = Join-Path $Root "repo"
$Canary = Join-Path $Root "HOST-SECRET-$Nonce.txt"
$CanaryValue = "HOST_ONLY_$Nonce"
$SavedSshAuthSock = $env:SSH_AUTH_SOCK
$InnerDockerMarker = "ocbox-inner-$Nonce"

New-Item -ItemType Directory -Force -Path $Repo | Out-Null
$CanaryValue | Set-Content -LiteralPath $Canary -Encoding ASCII
"safe baseline" | Set-Content -LiteralPath (Join-Path $Repo "README.txt") -Encoding ASCII

& git -C $Repo init -q
& git -C $Repo add README.txt
& git -C $Repo -c user.name="OCBox Security Test" -c user.email="security-test@localhost" commit -q -m "security baseline"
if ($LASTEXITCODE -ne 0) { throw "Impossibile creare il repository Git temporaneo." }

try {
    # Never intentionally hand the host SSH agent to the sandbox under test.
    Remove-Item Env:SSH_AUTH_SOCK -ErrorAction SilentlyContinue

    Write-Host "Creo microVM usa-e-getta: $SandboxName" -ForegroundColor Cyan
    Invoke-External "sbx" @(
        "create", "--name", $SandboxName,
        "--clone", "--no-share-skills",
        "shell", $Repo
    ) | Out-Null

    Invoke-External "sbx" @("policy", "allow", "network", "--sandbox", $SandboxName, "**") | Out-Null

    Write-Host "Raccolgo evidenze dall'interno della microVM..." -ForegroundColor DarkGray

    # 1. Full outbound web. Capture the real error instead of reducing it to an exit code.
    $Web = Invoke-SbxCapture -Sandbox $SandboxName -CommandArgs @("sh", "-lc", "if command -v curl >/dev/null 2>&1; then curl -fsSI --max-time 10 https://example.com | head -n 1; else echo OCBOX_NO_CURL; exit 127; fi")
    $WebDetail = if ($Web.Text) { $Web.Text } else { "exit=$($Web.ExitCode), nessun output" }
    Add-Result "Arbitrary HTTPS Internet" ($Web.ExitCode -eq 0) $WebDetail

    if ($Web.ExitCode -ne 0) {
        Write-Host ""
        Write-Host "[diagnostic] Policy applicate:" -ForegroundColor Yellow
        $Previous = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            & sbx policy ls $SandboxName --wide
            Write-Host "[diagnostic] Ultimi eventi di rete:" -ForegroundColor Yellow
            & sbx policy log $SandboxName --limit 10
        }
        finally {
            $ErrorActionPreference = $Previous
        }
        Write-Host ""
    }

    # 2. Public web must not imply access to RFC1918/LAN addresses.
    $Lan = Invoke-SbxCapture -Sandbox $SandboxName -CommandArgs @("sh", "-lc", "if command -v curl >/dev/null 2>&1; then curl -fsS --connect-timeout 3 --max-time 5 http://192.168.0.1 >/dev/null; else exit 127; fi")
    Add-Result "Private/LAN address blocked" ($Lan.ExitCode -ne 0) $(if ($Lan.Text) { $Lan.Text } else { "connection blocked/failed as expected" })

    # 3. Clone mode must expose the source repository read-only.
    $SourceWrite = Invoke-SbxCapture -Sandbox $SandboxName -CommandArgs @("sh", "-lc", "touch /run/sandbox/source/OCBOX_MUST_NOT_WRITE 2>/dev/null")
    Add-Result "Host repository source is read-only" ($SourceWrite.ExitCode -ne 0) "/run/sandbox/source write exit=$($SourceWrite.ExitCode)"

    # 4. Prove a private clone exists and can be modified without touching the host checkout.
    # sbx run shell starts in the primary clone workspace, unlike sbx exec whose default
    # working directory is not guaranteed to be the agent workspace.
    $CloneWrite = Invoke-SbxRunShellCapture -Sandbox $SandboxName -Command "printf sandbox > .ocbox-private-write-test && git rev-parse --show-toplevel"
    $HostWasModified = Test-Path -LiteralPath (Join-Path $Repo ".ocbox-private-write-test")
    $CloneDetail = if ($CloneWrite.Text) { $CloneWrite.Text } else { "exit=$($CloneWrite.ExitCode)" }
    Add-Result "Private clone does not modify host repo" (($CloneWrite.ExitCode -eq 0) -and (-not $HostWasModified)) $CloneDetail

    # 5. Try realistic Windows-to-Linux path aliases and require the exact canary bytes
    # before declaring an exposure. A mere test -r result is not enough evidence.
    $LeakedPaths = New-Object System.Collections.Generic.List[string]
    foreach ($Candidate in @(Get-WindowsPathCandidates -WindowsPath $Canary)) {
        $Read = Invoke-SbxCapture -Sandbox $SandboxName -CommandArgs @("sh", "-lc", "cat '$Candidate' 2>/dev/null")
        if ($Read.ExitCode -eq 0 -and $Read.Text -eq $CanaryValue) {
            $LeakedPaths.Add($Candidate)
        }
    }
    $CanarySafe = ($LeakedPaths.Count -eq 0)
    $CanaryDetail = if ($CanarySafe) { "canary host non leggibile tramite /c o /mnt/c" } else { "LEAK: " + ($LeakedPaths -join ", ") }
    Add-Result "Host file outside workspace inaccessible" $CanarySafe $CanaryDetail

    # 6. The host SSH agent must not cross the boundary.
    $Ssh = Invoke-SbxCapture -Sandbox $SandboxName -CommandArgs @("sh", "-lc", 'printf "%s" "${SSH_AUTH_SOCK-}"')
    $SshValue = $Ssh.Text.Trim()
    $SshSafe = [string]::IsNullOrWhiteSpace($SshValue)
    Add-Result "Host SSH agent not forwarded" $SshSafe $(if ($SshSafe) { "SSH_AUTH_SOCK vuoto" } else { "SSH_AUTH_SOCK=$SshValue" })

    # 7. Verify the sandbox Docker engine exists and is not the host Docker engine.
    $InnerDocker = Invoke-SbxCapture -Sandbox $SandboxName -CommandArgs @("sh", "-lc", "if command -v docker >/dev/null 2>&1; then docker volume create $InnerDockerMarker; else echo OCBOX_NO_DOCKER; exit 127; fi")
    $InnerDockerOk = ($InnerDocker.ExitCode -eq 0)
    Add-Result "Private Docker Engine available" $InnerDockerOk $(if ($InnerDocker.Text) { $InnerDocker.Text } else { "exit=$($InnerDocker.ExitCode)" })

    if ($InnerDockerOk -and (Get-Command docker -ErrorAction SilentlyContinue)) {
        $HostMarker = @(& docker volume ls -q --filter "name=^$InnerDockerMarker`$" 2>$null)
        $HostSeesInnerVolume = @($HostMarker | Where-Object { "$($_)".Trim() }).Count -gt 0
        Add-Result "Sandbox Docker is separate from host Docker" (-not $HostSeesInnerVolume) $(if ($HostSeesInnerVolume) { "host Docker vede $InnerDockerMarker" } else { "marker inner engine assente sull'host" })
        $null = Invoke-SbxCapture -Sandbox $SandboxName -CommandArgs @("sh", "-lc", "docker volume rm -f $InnerDockerMarker >/dev/null 2>&1")
    }
    elseif (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Add-Result "Sandbox Docker is separate from host Docker" $false "docker CLI host non disponibile: impossibile verificare separazione engine"
    }
}
finally {
    Write-Host "Distruggo la microVM di test..." -ForegroundColor Cyan
    $Previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & sbx rm --force $SandboxName 1>$null 2>$null
    }
    finally {
        $ErrorActionPreference = $Previous
    }

    if ($null -ne $SavedSshAuthSock) {
        $env:SSH_AUTH_SOCK = $SavedSshAuthSock
    }
    else {
        Remove-Item Env:SSH_AUTH_SOCK -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
$Results | Format-Table -AutoSize -Wrap
$Failures = @($Results | Where-Object { $_.Result -eq "FAIL" })
Write-Host ""
if ($Failures.Count -eq 0) {
    Write-Host "HOST ISOLATION: PASS ($($Results.Count)/$($Results.Count))" -ForegroundColor Green
}
else {
    Write-Host "HOST ISOLATION: FAIL ($($Failures.Count) failure/i)" -ForegroundColor Red
    throw "Security test fallito. Non usare il profilo unrestricted finche i FAIL non sono spiegati."
}
