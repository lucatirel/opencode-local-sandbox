[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "private\Common.ps1")

Assert-Command "sbx"
Assert-Command "git"

$Results = @()
function Add-Probe {
    param([string]$Name, [bool]$Ok, [string]$Detail)
    $script:Results += [pscustomobject]@{
        Result = if ($Ok) { "PASS" } else { "FAIL" }
        Probe = $Name
        Detail = $Detail
    }
    $Color = if ($Ok) { "Green" } else { "Red" }
    Write-Host ("{0}: {1}" -f $(if ($Ok) { "PASS" } else { "FAIL" }), $Name) -ForegroundColor $Color
    if (-not [string]::IsNullOrWhiteSpace($Detail)) {
        Write-Host "      $Detail" -ForegroundColor DarkGray
    }
}

function Run-Sbx {
    param([string]$Sandbox, [string[]]$Args)
    $Old = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $Out = @(& sbx exec $Sandbox @Args 2>&1)
        $Code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $Old }
    [pscustomobject]@{
        Code = $Code
        Text = (($Out | ForEach-Object { "$($_)" }) -join "`n").Trim()
    }
}

function Policy-Decision {
    param([string]$Sandbox, [string]$Target)
    $Old = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $Out = @(& sbx policy check network --sandbox $Sandbox $Target 2>&1)
    }
    finally { $ErrorActionPreference = $Old }
    $Text = (($Out | ForEach-Object { "$($_)" }) -join "`n")
    if ($Text -match '(?i)Allowed') { return "allow" }
    if ($Text -match '(?i)Denied') { return "deny" }
    return "unknown"
}

Write-Host ""
Write-Host "OCBox controlled adversarial containment test" -ForegroundColor Cyan
Write-Host "This test uses inert canaries and read-only/probing operations only." -ForegroundColor DarkGray
Write-Host "It does not exploit unknown vulnerabilities and performs no destructive remote actions." -ForegroundColor DarkGray
Write-Host ""

$Nonce = [Guid]::NewGuid().ToString("N").Substring(0, 8)
$Sandbox = "oc-adversarial-$Nonce"
$Root = Join-Path $env:TEMP "ocbox-adversarial-$Nonce"
$Repo = Join-Path $Root "repo"
$Canary = Join-Path $Root "HOST-PRIVATE-$Nonce.txt"
$CanaryValue = "OCBOX_HOST_ONLY_$Nonce"
$HostDockerMarker = "ocbox-adversarial-$Nonce"

New-Item -ItemType Directory -Force -Path $Repo | Out-Null
$CanaryValue | Set-Content -LiteralPath $Canary -Encoding ASCII
"adversarial test baseline" | Set-Content -LiteralPath (Join-Path $Repo "README.txt") -Encoding ASCII
& git -C $Repo init -q
& git -C $Repo add README.txt
& git -C $Repo -c user.name="OCBox Adversarial Test" -c user.email="adversarial@localhost" commit -q -m "baseline"
if ($LASTEXITCODE -ne 0) { throw "Could not create temporary Git repository." }

try {
    Write-Host "[1/3] Creating disposable sandbox: $Sandbox" -ForegroundColor Cyan
    Write-Host "      sbx create may remain quiet for a while." -ForegroundColor DarkGray
    $Started = Get-Date
    Invoke-External "sbx" @("create", "--name", $Sandbox, "--clone", "--no-share-skills", "shell", $Repo) | Out-Null
    Write-Host ("      Sandbox ready in {0:n1}s." -f ((Get-Date) - $Started).TotalSeconds) -ForegroundColor DarkGray

    Invoke-External "sbx" @("policy", "allow", "network", "--sandbox", $Sandbox, "**:80,**:443") | Out-Null
    $Deny = @((Get-PrivateNetworkDenyResources) + @("localhost:80", "localhost:443"))
    Invoke-External "sbx" @("policy", "deny", "network", "--sandbox", $Sandbox, ($Deny -join ",")) | Out-Null

    Write-Host ""
    Write-Host "[2/3] Probing containment boundaries" -ForegroundColor Cyan

    $R = Run-Sbx $Sandbox @("sh", "-lc", 'for n in GITHUB_TOKEN GH_TOKEN AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AZURE_CLIENT_SECRET GOOGLE_APPLICATION_CREDENTIALS SSH_AUTH_SOCK; do eval "v=\${$n:-}"; [ -n "$v" ] && printf "%s\n" "$n"; done')
    Add-Probe "No high-value host credential environment forwarded" ([string]::IsNullOrWhiteSpace($R.Text)) $(if ($R.Text) { "present variable names: $($R.Text -replace "`n", ', ')" } else { "GitHub/cloud/SSH credential variables absent" })

    $R = Run-Sbx $Sandbox @("sh", "-lc", 'if command -v gh >/dev/null 2>&1; then gh auth status >/tmp/gh-status 2>&1; c=$?; cat /tmp/gh-status; exit $c; else echo "gh CLI not installed"; exit 1; fi')
    Add-Probe "GitHub CLI has no authenticated session" ($R.Code -ne 0) $(if ($R.Text) { $R.Text } else { "gh auth status returned unauthenticated" })

    $R = Run-Sbx $Sandbox @("sh", "-lc", "env -u GITHUB_TOKEN -u GH_TOKEN curl -sS --max-time 10 -o /dev/null -w '%{http_code}' https://api.github.com/user")
    Add-Probe "GitHub API sees sandbox as anonymous" (($R.Code -eq 0) -and ($R.Text -eq "401")) "HTTP $($R.Text) from /user (expected 401)"

    $R = Run-Sbx $Sandbox @("sh", "-lc", 'for p in "$HOME/.git-credentials" "$HOME/.config/gh/hosts.yml" "$HOME/.ssh/id_rsa" "$HOME/.ssh/id_ed25519" "$HOME/.aws/credentials"; do [ -e "$p" ] && printf "%s\n" "$p"; done')
    Add-Probe "Common credential files absent" ([string]::IsNullOrWhiteSpace($R.Text)) $(if ($R.Text) { "found: $($R.Text -replace "`n", ', ')" } else { "no GitHub/Git/SSH/AWS credential files found" })

    $R = Run-Sbx $Sandbox @("sh", "-lc", 'touch /run/sandbox/source/OCBOX_ADVERSARIAL_WRITE 2>/dev/null')
    Add-Probe "Host source mount remains read-only" ($R.Code -ne 0) "write exit=$($R.Code)"

    $Full = [IO.Path]::GetFullPath($Canary)
    $Candidates = @()
    if ($Full -match '^([A-Za-z]):\\(.*)$') {
        $Drive = $Matches[1].ToLowerInvariant()
        $Rest = $Matches[2].Replace('\','/')
        $Candidates = @("/$Drive/$Rest", "/mnt/$Drive/$Rest", "/host_mnt/$Drive/$Rest")
    }
    $Leak = $false
    $LeakAt = ""
    foreach ($Candidate in $Candidates) {
        $R = Run-Sbx $Sandbox @("sh", "-lc", "cat '$Candidate' 2>/dev/null")
        if (($R.Code -eq 0) -and ($R.Text -eq $CanaryValue)) { $Leak = $true; $LeakAt = $Candidate; break }
    }
    Add-Probe "Arbitrary host file canary inaccessible" (-not $Leak) $(if ($Leak) { "LEAK at $LeakAt" } else { "host-only canary could not be read" })

    $PrivateTargets = @("10.0.0.1:80", "172.16.0.1:80", "192.168.1.1:80", "169.254.169.254:80")
    $Bad = @($PrivateTargets | Where-Object { (Policy-Decision $Sandbox $_) -ne "deny" })
    Add-Probe "Private/LAN/metadata routes remain denied" ($Bad.Count -eq 0) $(if ($Bad.Count) { "not denied: $($Bad -join ', ')" } else { "all representative targets denied" })

    $R = Run-Sbx $Sandbox @("sh", "-lc", 'docker info >/dev/null 2>&1 && docker volume create ' + $HostDockerMarker)
    $InnerDocker = ($R.Code -eq 0)
    Add-Probe "Private Docker Engine is available" $InnerDocker $(if ($R.Text) { $R.Text } else { "exit=$($R.Code)" })

    if ($InnerDocker) {
        $Old = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            & cmd.exe /c "docker info >nul 2>nul"
            $HostDockerAvailable = ($LASTEXITCODE -eq 0)
        }
        finally { $ErrorActionPreference = $Old }

        if ($HostDockerAvailable) {
            $Old = $ErrorActionPreference
            try {
                $ErrorActionPreference = "Continue"
                $Seen = @(& docker volume ls -q --filter "name=$HostDockerMarker" 2>$null | Where-Object { "$($_)".Trim() -eq $HostDockerMarker }).Count -gt 0
            }
            finally { $ErrorActionPreference = $Old }
            Add-Probe "Inner Docker cannot mutate host Docker" (-not $Seen) $(if ($Seen) { "host Docker saw inner marker volume" } else { "inner marker absent from host Docker" })
        }
        else {
            Add-Probe "Inner Docker cannot mutate host Docker" $true "host Docker daemon unavailable; inner engine still worked independently"
        }
        $null = Run-Sbx $Sandbox @("sh", "-lc", "docker volume rm -f $HostDockerMarker >/dev/null 2>&1")
    }

    Write-Host ""
    Write-Host "[3/3] Verifying host state" -ForegroundColor Cyan
    $HostCanaryStillValid = (Test-Path -LiteralPath $Canary) -and ((Get-Content -LiteralPath $Canary -Raw).Trim() -eq $CanaryValue)
    Add-Probe "Host canary unchanged" $HostCanaryStillValid "host-only sentinel preserved"
}
finally {
    Write-Host ""
    Write-Host "Destroying adversarial test sandbox..." -ForegroundColor Cyan
    $Old = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & sbx rm --force $Sandbox 1>$null 2>$null
    }
    finally { $ErrorActionPreference = $Old }
    Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
$Failures = @($Results | Where-Object { $_.Result -eq "FAIL" })
if ($Failures.Count -eq 0) {
    Write-Host "ADVERSARIAL CONTAINMENT: PASS ($($Results.Count)/$($Results.Count))" -ForegroundColor Green
}
else {
    Write-Host "ADVERSARIAL CONTAINMENT: FAIL ($($Failures.Count) failure/i)" -ForegroundColor Red
    $Failures | Format-Table -AutoSize -Wrap
    throw "One or more adversarial containment probes failed."
}
