[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "private\Common.ps1")

Assert-Command "sbx"
Assert-Command "git"

function To-SandboxPath {
    param([Parameter(Mandatory = $true)][string]$WindowsPath)
    $Full = [IO.Path]::GetFullPath($WindowsPath)
    if ($Full -match '^([A-Za-z]):\\(.*)$') {
        return "/$($Matches[1].ToLowerInvariant())/$($Matches[2].Replace('\','/'))"
    }
    return $Full.Replace('\','/')
}

function Add-Result {
    param([string]$Name, [bool]$Passed, [string]$Detail)
    $script:Results.Add([pscustomobject]@{
        Result = if ($Passed) { "PASS" } else { "FAIL" }
        Check  = $Name
        Detail = $Detail
    })
}

function Invoke-SbxExitCode {
    param([string]$Sandbox, [string[]]$Args)
    $Previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & sbx exec $Sandbox @Args 1>$null 2>$null
        return $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $Previous
    }
}

$Results = New-Object System.Collections.Generic.List[object]
$Nonce = [Guid]::NewGuid().ToString("N").Substring(0, 8)
$SandboxName = "oc-security-$Nonce"
$Root = Join-Path $env:TEMP "ocbox-security-$Nonce"
$Repo = Join-Path $Root "repo"
$Canary = Join-Path $Root "HOST-SECRET-$Nonce.txt"
$SavedSshAuthSock = $env:SSH_AUTH_SOCK

New-Item -ItemType Directory -Force -Path $Repo | Out-Null
"HOST_ONLY_$Nonce" | Set-Content -LiteralPath $Canary -Encoding ASCII
"safe baseline" | Set-Content -LiteralPath (Join-Path $Repo "README.txt") -Encoding ASCII

& git -C $Repo init -q
& git -C $Repo add README.txt
& git -C $Repo -c user.name="OCBox Security Test" -c user.email="security-test@localhost" commit -q -m "security baseline"
if ($LASTEXITCODE -ne 0) { throw "Impossibile creare il repository Git temporaneo." }

try {
    Remove-Item Env:SSH_AUTH_SOCK -ErrorAction SilentlyContinue

    Write-Host "Creo microVM usa-e-getta: $SandboxName" -ForegroundColor Cyan
    Invoke-External "sbx" @(
        "create", "--name", $SandboxName,
        "--clone", "--no-share-skills",
        "shell", $Repo
    ) | Out-Null

    Invoke-External "sbx" @("policy", "allow", "network", "--sandbox", $SandboxName, "**") | Out-Null

    $Code = Invoke-SbxExitCode -Sandbox $SandboxName -Args @("sh", "-lc", "curl -fsS --max-time 10 https://example.com >/dev/null")
    Add-Result "Arbitrary HTTPS Internet" ($Code -eq 0) "example.com deve essere raggiungibile"

    $Code = Invoke-SbxExitCode -Sandbox $SandboxName -Args @("sh", "-lc", "curl -fsS --connect-timeout 3 --max-time 5 http://192.168.0.1 >/dev/null")
    Add-Result "Private/LAN address blocked" ($Code -ne 0) "192.168.0.1 non deve essere raggiungibile"

    $Code = Invoke-SbxExitCode -Sandbox $SandboxName -Args @("sh", "-lc", "touch /run/sandbox/source/OCBOX_MUST_NOT_WRITE 2>/dev/null")
    Add-Result "Host repository source is read-only" ($Code -ne 0) "/run/sandbox/source non deve essere scrivibile"

    $Code = Invoke-SbxExitCode -Sandbox $SandboxName -Args @("sh", "-lc", "printf sandbox > .ocbox-private-write-test")
    $HostWasModified = Test-Path -LiteralPath (Join-Path $Repo ".ocbox-private-write-test")
    Add-Result "Private clone does not modify host repo" (($Code -eq 0) -and (-not $HostWasModified)) "scrittura VM riuscita, file assente sul repo host"

    $CanarySandboxPath = To-SandboxPath $Canary
    $Code = Invoke-SbxExitCode -Sandbox $SandboxName -Args @("sh", "-lc", "test ! -r '$CanarySandboxPath'")
    Add-Result "Host file outside workspace inaccessible" ($Code -eq 0) $CanarySandboxPath

    # Single-quoted PowerShell string keeps $SSH_AUTH_SOCK literal for the shell
    # running inside the sandbox instead of interpolating it on the Windows host.
    $Code = Invoke-SbxExitCode -Sandbox $SandboxName -Args @("sh", "-lc", 'test -z "$SSH_AUTH_SOCK"')
    Add-Result "Host SSH agent not forwarded" ($Code -eq 0) "SSH_AUTH_SOCK deve essere vuoto"

    $Code = Invoke-SbxExitCode -Sandbox $SandboxName -Args @("sh", "-lc", "docker info >/dev/null 2>&1")
    Add-Result "Private Docker Engine available" ($Code -eq 0) "Docker deve funzionare dentro la microVM"
}
finally {
    Write-Host "Distruggo la microVM di test..." -ForegroundColor Cyan
    $Previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & sbx rm $SandboxName -f 1>$null 2>$null
    }
    finally {
        $ErrorActionPreference = $Previous
    }

    if ($null -ne $SavedSshAuthSock) {
        $env:SSH_AUTH_SOCK = $SavedSshAuthSock
    }
    Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
$Results | Format-Table -AutoSize
$Failures = @($Results | Where-Object { $_.Result -eq "FAIL" })
Write-Host ""
if ($Failures.Count -eq 0) {
    Write-Host "HOST ISOLATION: PASS ($($Results.Count)/$($Results.Count))" -ForegroundColor Green
}
else {
    Write-Host "HOST ISOLATION: FAIL ($($Failures.Count) failure/i)" -ForegroundColor Red
    throw "Security test fallito. Non usare il profilo unrestricted finche i FAIL non sono spiegati."
}
