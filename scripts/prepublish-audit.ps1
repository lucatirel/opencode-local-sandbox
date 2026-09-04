[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "private\Common.ps1")

Assert-Command "git"
Assert-GitRepository (Get-ToolRoot)

$ToolRoot = Get-ToolRoot
$Findings = @()
$Warnings = @()

function Add-Finding {
    param([string]$Category, [string]$Path, [string]$Detail)
    $script:Findings += [pscustomobject]@{
        Category = $Category
        Path = $Path
        Detail = $Detail
    }
}

function Add-Warning {
    param([string]$Category, [string]$Path, [string]$Detail)
    $script:Warnings += [pscustomobject]@{
        Category = $Category
        Path = $Path
        Detail = $Detail
    }
}

function Invoke-GitText {
    param([string[]]$ArgumentList)
    $Old = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $Out = @(& git -C $ToolRoot @ArgumentList 2>&1)
        $Code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $Old }

    if ($Code -ne 0) {
        throw "git $($ArgumentList -join ' ') failed: $((($Out | ForEach-Object { \"$($_)\" }) -join \"`n\").Trim())"
    }

    return (($Out | ForEach-Object { "$($_)" }) -join "`n").Trim()
}

Write-Host ""
Write-Host "OCBox pre-publication audit" -ForegroundColor Cyan
Write-Host "Scope: current main branch plus its complete reachable Git history." -ForegroundColor DarkGray
Write-Host "Secret values are never printed; findings show only category, path and object id." -ForegroundColor DarkGray
Write-Host ""

Write-Host "[1/6] Repository state" -ForegroundColor Cyan
$CurrentBranch = Invoke-GitText @("branch", "--show-current")
if ($CurrentBranch -ne "main") {
    Add-Finding "Repository state" "-" "current branch is '$CurrentBranch', expected 'main'"
}

$Status = Invoke-GitText @("status", "--porcelain")
if (-not [string]::IsNullOrWhiteSpace($Status)) {
    Add-Finding "Repository state" "-" "working tree is not clean"
}
else {
    Write-Host "      PASS: clean working tree on main" -ForegroundColor Green
}

Write-Host "[2/6] Branch surface" -ForegroundColor Cyan
$RemoteBranchesText = Invoke-GitText @("for-each-ref", "--format=%(refname:short)", "refs/remotes/origin")
$RemoteBranches = @($RemoteBranchesText -split "`r?`n" | Where-Object { $_ -and $_ -ne "origin/HEAD" })
$UnexpectedRemote = @($RemoteBranches | Where-Object { $_ -ne "origin/main" })
if ($UnexpectedRemote.Count -gt 0) {
    Add-Finding "Branch surface" "-" ("unexpected remote branch(es): " + ($UnexpectedRemote -join ", "))
}
else {
    Write-Host "      PASS: origin exposes only main" -ForegroundColor Green
}

$LocalBranchesText = Invoke-GitText @("for-each-ref", "--format=%(refname:short)", "refs/heads")
$LocalBranches = @($LocalBranchesText -split "`r?`n" | Where-Object { $_ })
$UnexpectedLocal = @($LocalBranches | Where-Object { $_ -ne "main" })
if ($UnexpectedLocal.Count -gt 0) {
    Add-Warning "Local branches" "-" ("local-only branch(es) remain: " + ($UnexpectedLocal -join ", "))
}
else {
    Write-Host "      PASS: main is the only local branch" -ForegroundColor Green
}

Write-Host "[3/6] Historical file names" -ForegroundColor Cyan
$ObjectLines = @(Invoke-GitText @("rev-list", "--objects", "main") -split "`r?`n")
$BlobRecords = @{}
$SuspiciousPathPattern = '(?i)(^|/)(\.env($|\.)|config\.local\.ps1$|credentials($|\.)|secrets?($|\.)|id_(rsa|ed25519|ecdsa|dsa)$|[^/]+\.(pem|key|p12|pfx|kdbx)$|hosts\.yml$)'
$BinaryExtensions = @(".png", ".jpg", ".jpeg", ".gif", ".webp", ".ico", ".pdf", ".zip", ".7z", ".gz", ".tar", ".exe", ".dll", ".so", ".bin", ".gguf", ".onnx", ".pt", ".pth")

$Count = 0
foreach ($Line in $ObjectLines) {
    if ([string]::IsNullOrWhiteSpace($Line)) { continue }
    $Parts = $Line -split ' ', 2
    if ($Parts.Count -lt 2) { continue }
    $Sha = $Parts[0]
    $Path = $Parts[1]

    $Type = Invoke-GitText @("cat-file", "-t", $Sha)
    if ($Type -ne "blob") { continue }

    $Key = "$Sha|$Path"
    if (-not $BlobRecords.ContainsKey($Key)) {
        $BlobRecords[$Key] = [pscustomobject]@{ Sha = $Sha; Path = $Path }
    }

    if ($Path -match $SuspiciousPathPattern) {
        Add-Finding "Sensitive historical filename" $Path "reachable blob $Sha"
    }

    $Count++
    if (($Count % 100) -eq 0) {
        Write-Host "      ...inspected $Count historical blob paths" -ForegroundColor DarkGray
    }
}
Write-Host ("      Historical blob paths inspected: {0}" -f $BlobRecords.Count) -ForegroundColor DarkGray

Write-Host "[4/6] Secret signatures in historical blobs" -ForegroundColor Cyan
$HardPatterns = @(
    [pscustomobject]@{ Name = "Private key"; Regex = '-----BEGIN (RSA |OPENSSH |EC |DSA )?PRIVATE KEY-----' },
    [pscustomobject]@{ Name = "GitHub token"; Regex = '(?<![A-Za-z0-9_])gh[pousr]_[A-Za-z0-9]{20,}' },
    [pscustomobject]@{ Name = "GitHub fine-grained PAT"; Regex = 'github_pat_[A-Za-z0-9_]{20,}' },
    [pscustomobject]@{ Name = "AWS access key"; Regex = '(?<![A-Z0-9])AKIA[0-9A-Z]{16}(?![A-Z0-9])' },
    [pscustomobject]@{ Name = "Google API key"; Regex = 'AIza[0-9A-Za-z_-]{35}' },
    [pscustomobject]@{ Name = "Slack token"; Regex = 'xox[baprs]-[0-9A-Za-z-]{20,}' },
    [pscustomobject]@{ Name = "OpenAI-style secret"; Regex = '(?<![A-Za-z0-9_-])sk-(?:proj-)?[A-Za-z0-9_-]{20,}' }
)

$Scanned = 0
foreach ($Record in $BlobRecords.Values) {
    $Path = $Record.Path
    $Sha = $Record.Sha
    $Ext = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    if ($BinaryExtensions -contains $Ext) { continue }

    $SizeText = Invoke-GitText @("cat-file", "-s", $Sha)
    $Size = 0L
    if (-not [Int64]::TryParse($SizeText, [ref]$Size)) { continue }

    if ($Size -gt 10485760) {
        Add-Warning "Large historical blob" $Path ("$Sha is $([Math]::Round($Size / 1MB, 1)) MB")
    }
    if ($Size -gt 2097152) { continue }

    $Content = Invoke-GitText @("cat-file", "blob", $Sha)
    foreach ($Pattern in $HardPatterns) {
        if ($Content -match $Pattern.Regex) {
            Add-Finding "Secret signature: $($Pattern.Name)" $Path "reachable blob $Sha"
        }
    }

    if ($Content -match '(?i)C:\\Users\\[^\\\s]+\\') {
        Add-Warning "Personal absolute path" $Path "reachable blob $Sha contains a C:\\Users\\... path"
    }

    $Scanned++
    if (($Scanned % 50) -eq 0) {
        Write-Host "      ...content-scanned $Scanned historical text blobs" -ForegroundColor DarkGray
    }
}
Write-Host ("      Historical text blobs content-scanned: {0}" -f $Scanned) -ForegroundColor DarkGray

Write-Host "[5/6] Current-tree release files" -ForegroundColor Cyan
$Required = @("README.md", "SECURITY.md", "CONTRIBUTING.md", "PROJECT_STATUS.md", "LICENSE")
foreach ($Name in $Required) {
    if (-not (Test-Path -LiteralPath (Join-Path $ToolRoot $Name))) {
        if ($Name -eq "LICENSE") {
            Add-Warning "Release metadata" $Name "no LICENSE file present"
        }
        else {
            Add-Finding "Release metadata" $Name "required release file missing"
        }
    }
}

$IgnoredLocal = Invoke-GitText @("check-ignore", "config.local.ps1")
if ($IgnoredLocal -ne "config.local.ps1") {
    Add-Finding "Ignore policy" "config.local.ps1" "machine-local config is not ignored"
}
else {
    Write-Host "      PASS: config.local.ps1 is ignored" -ForegroundColor Green
}

Write-Host "[6/6] Audit result" -ForegroundColor Cyan
Write-Host ""

if ($Warnings.Count -gt 0) {
    Write-Host "REVIEW WARNINGS" -ForegroundColor Yellow
    $Warnings | Format-Table Category, Path, Detail -AutoSize -Wrap
    Write-Host ""
}

if ($Findings.Count -gt 0) {
    Write-Host "PRE-PUBLICATION AUDIT: FAIL ($($Findings.Count) blocking finding(s))" -ForegroundColor Red
    $Findings | Format-Table Category, Path, Detail -AutoSize -Wrap
    throw "Pre-publication audit failed. Keep the repository private until all blocking findings are resolved."
}

Write-Host "PRE-PUBLICATION AUDIT: PASS" -ForegroundColor Green
Write-Host "No blocking secret signatures or release-surface problems were found in reachable main history." -ForegroundColor Green
if ($Warnings.Count -gt 0) {
    Write-Host "Review the warnings above before changing repository visibility." -ForegroundColor Yellow
}
