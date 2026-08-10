[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "private\Common.ps1")

Assert-Command "sbx"
Assert-Command "git"

function Add-Check($Name, $Ok, $Detail) {
    $script:Results += [pscustomobject]@{
        Result = if ($Ok) { "PASS" } else { "FAIL" }
        Check = $Name
        Detail = $Detail
    }
}

function Run-Sbx($Sandbox, [string[]]$CommandArgs) {
    $Old = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $Out = @(& sbx exec $Sandbox @CommandArgs 2>&1)
        $Code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $Old }
    [pscustomobject]@{
        Code = $Code
        Text = (($Out | ForEach-Object { "$($_)" }) -join "`n").Trim()
    }
}

function Run-AgentShell($Sandbox, $Command) {
    $Old = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $Out = @(& sbx run shell --name $Sandbox -- -c $Command 2>&1)
        $Code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $Old }
    [pscustomobject]@{
        Code = $Code
        Text = (($Out | ForEach-Object { "$($_)" }) -join "`n").Trim()
    }
}

function Check-NetworkPolicy($Sandbox, $Target) {
    $Old = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $Out = @(& sbx policy check network --sandbox $Sandbox $Target 2>&1)
        $Code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $Old }
    [pscustomobject]@{
        Code = $Code
        Text = (($Out | ForEach-Object { "$($_)" }) -join "`n").Trim()
    }
}

$Results = @()
$Nonce = [Guid]::NewGuid().ToString("N").Substring(0, 8)
$Sandbox = "oc-security-$Nonce"
$Root = Join-Path $env:TEMP "ocbox-security-$Nonce"
$Repo = Join-Path $Root "repo"
$Canary = Join-Path $Root "HOST-SECRET-$Nonce.txt"
$CanaryValue = "HOST_ONLY_$Nonce"
$SavedSsh = $env:SSH_AUTH_SOCK
$DockerMarker = "ocbox-inner-$Nonce"

New-Item -ItemType Directory -Force -Path $Repo | Out-Null
$CanaryValue | Set-Content -LiteralPath $Canary -Encoding ASCII
"safe baseline" | Set-Content -LiteralPath (Join-Path $Repo "README.txt") -Encoding ASCII
& git -C $Repo init -q
& git -C $Repo add README.txt
& git -C $Repo -c user.name="OCBox Security Test" -c user.email="security-test@localhost" commit -q -m "baseline"
if ($LASTEXITCODE -ne 0) { throw "Impossibile creare il repository Git temporaneo." }

try {
    Remove-Item Env:SSH_AUTH_SOCK -ErrorAction SilentlyContinue

    Write-Host "Creo microVM usa-e-getta: $Sandbox" -ForegroundColor Cyan
    Invoke-External "sbx" @("create", "--name", $Sandbox, "--clone", "--no-share-skills", "shell", $Repo) | Out-Null
    Invoke-External "sbx" @("policy", "allow", "network", "--sandbox", $Sandbox, "**") | Out-Null

    $PrivateDeny = @(Get-PrivateNetworkDenyResources)
    Invoke-External "sbx" @("policy", "deny", "network", "--sandbox", $Sandbox, ($PrivateDeny -join ",")) | Out-Null

    Write-Host "Raccolgo evidenze dall'interno della microVM..." -ForegroundColor DarkGray

    $R = Run-Sbx $Sandbox @("sh", "-lc", "curl -fsSI --max-time 10 https://example.com | head -n 1")
    Add-Check "Arbitrary HTTPS Internet" ($R.Code -eq 0) $(if ($R.Text) { $R.Text } else { "exit=$($R.Code)" })

    $PolicyTargets = @("10.0.0.1:80", "172.16.0.1:80", "192.168.0.1:80", "192.168.1.1:80", "100.64.0.1:80", "169.254.169.254:80")
    $PolicyMisses = @()
    $PolicyDetails = @()
    foreach ($Target in $PolicyTargets) {
        $P = Check-NetworkPolicy $Sandbox $Target
        $Denied = ($P.Text -match '(?i)Denied')
        if (-not $Denied) { $PolicyMisses += $Target }
        $PolicyDetails += "$Target=$(if ($Denied) {'DENY'} else {'NOT-DENY'})"
    }
    Add-Check "Private CIDR policy denies" ($PolicyMisses.Count -eq 0) $(if ($PolicyMisses.Count -eq 0) { $PolicyDetails -join "; " } else { "NOT DENIED: " + ($PolicyMisses -join ", ") })

    # Host canary bound only to loopback. This avoids Windows Defender Firewall
    # prompts and tests the Docker-specific host.docker.internal exception path.
    # A random host port must remain unreachable unless localhost:<port> is
    # explicitly allowed by sandbox policy (llama:8080 is the intended exception
    # in the real work sandbox, not in this disposable test sandbox).
    $Listener = $null
    $Client = $null
    try {
        $Listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
        $Listener.Start()
        $Port = ([System.Net.IPEndPoint]$Listener.LocalEndpoint).Port
        $AcceptTask = $Listener.AcceptTcpClientAsync()

        $P = Check-NetworkPolicy $Sandbox "localhost:$Port"
        $PolicyDenied = ($P.Text -match '(?i)Denied')

        $null = Run-Sbx $Sandbox @("sh", "-lc", "curl --noproxy '*' -sS --connect-timeout 2 --max-time 3 telnet://host.docker.internal:$Port </dev/null >/dev/null 2>&1")
        Start-Sleep -Milliseconds 250

        $Accepted = $AcceptTask.IsCompleted
        if ($Accepted) {
            try { $Client = $AcceptTask.Result } catch { $Client = $null }
        }
        $HostSafe = ($PolicyDenied -and (-not $Accepted))
        Add-Check "Unapproved host service unreachable" $HostSafe "localhost:$Port policy=$(if ($PolicyDenied) {'DENY'} else {'NOT-DENY'}) accepted=$Accepted"
    }
    finally {
        if ($null -ne $Client) { $Client.Dispose() }
        if ($null -ne $Listener) { $Listener.Stop() }
    }

    $R = Run-Sbx $Sandbox @("sh", "-lc", "touch /run/sandbox/source/OCBOX_MUST_NOT_WRITE 2>/dev/null")
    Add-Check "Host repository source read-only" ($R.Code -ne 0) "write exit=$($R.Code)"

    $R = Run-AgentShell $Sandbox "printf sandbox > .ocbox-private-write-test && git rev-parse --show-toplevel"
    $HostChanged = Test-Path -LiteralPath (Join-Path $Repo ".ocbox-private-write-test")
    Add-Check "Private clone isolated from host repo" (($R.Code -eq 0) -and (-not $HostChanged)) $(if ($R.Text) { $R.Text } else { "exit=$($R.Code)" })

    $Full = [IO.Path]::GetFullPath($Canary)
    $Leak = $false
    $LeakAt = ""
    if ($Full -match '^([A-Za-z]):\\(.*)$') {
        $Drive = $Matches[1].ToLowerInvariant()
        $Rest = $Matches[2].Replace('\','/')
        foreach ($Candidate in @("/$Drive/$Rest", "/mnt/$Drive/$Rest")) {
            $R = Run-Sbx $Sandbox @("sh", "-lc", "cat '$Candidate' 2>/dev/null")
            if (($R.Code -eq 0) -and ($R.Text -eq $CanaryValue)) { $Leak = $true; $LeakAt = $Candidate }
        }
    }
    Add-Check "Host file outside workspace inaccessible" (-not $Leak) $(if ($Leak) { "LEAK: $LeakAt" } else { "host canary not readable" })

    $R = Run-Sbx $Sandbox @("sh", "-lc", 'printf "%s" "${SSH_AUTH_SOCK:-}"')
    Add-Check "Host SSH agent not forwarded" ([string]::IsNullOrWhiteSpace($R.Text)) $(if ($R.Text) { "SSH_AUTH_SOCK=$($R.Text)" } else { "SSH_AUTH_SOCK empty" })

    $R = Run-Sbx $Sandbox @("sh", "-lc", "docker volume create $DockerMarker")
    $InnerDockerOk = ($R.Code -eq 0)
    Add-Check "Private Docker Engine available" $InnerDockerOk $(if ($R.Text) { $R.Text } else { "exit=$($R.Code)" })

    if ($InnerDockerOk) {
        $Old = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            & cmd.exe /c "docker info >nul 2>nul"
            $HostDockerOk = ($LASTEXITCODE -eq 0)
        }
        finally { $ErrorActionPreference = $Old }

        if (-not $HostDockerOk) {
            Add-Check "Sandbox Docker separate from host" $true "inner engine works while host Docker daemon is unavailable"
        }
        else {
            $Old = $ErrorActionPreference
            try {
                $ErrorActionPreference = "Continue"
                $HostMarker = @(& docker volume ls -q --filter "name=$DockerMarker" 2>$null)
            }
            finally { $ErrorActionPreference = $Old }
            $Seen = @($HostMarker | Where-Object { "$($_)".Trim() -eq $DockerMarker }).Count -gt 0
            Add-Check "Sandbox Docker separate from host" (-not $Seen) $(if ($Seen) { "FAIL: host sees inner volume" } else { "inner volume absent on host engine" })
        }
        $null = Run-Sbx $Sandbox @("sh", "-lc", "docker volume rm -f $DockerMarker >/dev/null 2>&1")
    }
}
finally {
    Write-Host "Distruggo la microVM di test..." -ForegroundColor Cyan
    $Old = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & sbx rm --force $Sandbox 1>$null 2>$null
    }
    finally { $ErrorActionPreference = $Old }

    if ($null -ne $SavedSsh) { $env:SSH_AUTH_SOCK = $SavedSsh }
    else { Remove-Item Env:SSH_AUTH_SOCK -ErrorAction SilentlyContinue }
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
