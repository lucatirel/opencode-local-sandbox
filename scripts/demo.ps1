[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "private\Common.ps1")

Assert-Command "git"

$ToolRoot = Get-ToolRoot
$DemoRoot = Join-Path ([Environment]::GetFolderPath("Desktop")) "OCBox-Demo"
$OpenScript = Join-Path $PSScriptRoot "open-project.ps1"
$ReviewScript = Join-Path $PSScriptRoot "review-project.ps1"
$Prompt = "Create a file named hello.txt containing exactly: OCBox demo: agent wrote this inside the sandbox. Then show git status. Do not modify README.md."

Write-Host ""
Write-Host "OCBox launch demo" -ForegroundColor Cyan
Write-Host "This creates a disposable demo Git repository on your Desktop." -ForegroundColor DarkGray
Write-Host "The host repository must remain unchanged while the agent works in the sandbox clone." -ForegroundColor DarkGray
Write-Host ""

if (Test-Path -LiteralPath $DemoRoot) {
    throw "Demo path already exists: $DemoRoot`nRename/remove it first so the recording starts from a known-clean repository."
}

New-Item -ItemType Directory -Path $DemoRoot | Out-Null
"# OCBox Demo`n`nThis file exists on the Windows host before the sandbox starts.`n" | Set-Content -LiteralPath (Join-Path $DemoRoot "README.md") -Encoding UTF8

& git -C $DemoRoot init -q
if ($LASTEXITCODE -ne 0) { throw "Could not initialize demo repository." }
& git -C $DemoRoot branch -M main
& git -C $DemoRoot add README.md
& git -C $DemoRoot -c user.name="OCBox Demo" -c user.email="demo@localhost" commit -q -m "Demo baseline"
if ($LASTEXITCODE -ne 0) { throw "Could not create demo baseline commit." }

$Baseline = (& git -C $DemoRoot rev-parse HEAD).Trim()

Write-Host "DEMO REPOSITORY" -ForegroundColor Cyan
Write-Host "  $DemoRoot"
Write-Host ""
Write-Host "HOST BEFORE" -ForegroundColor Cyan
& git -C $DemoRoot status -sb
Write-Host "  HEAD: $Baseline" -ForegroundColor DarkGray
Write-Host ""

try {
    Set-Clipboard -Value $Prompt
    Write-Host "Prompt copied to clipboard." -ForegroundColor Green
}
catch {
    Write-Host "Could not copy prompt automatically; copy it from below." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "PROMPT TO PASTE INTO OPENCODE" -ForegroundColor Cyan
Write-Host $Prompt -ForegroundColor Yellow
Write-Host ""
Write-Host "Recording sequence:" -ForegroundColor Cyan
Write-Host "  1. Start screen recording now."
Write-Host "  2. Press ENTER here."
Write-Host "  3. Paste the prompt into OpenCode."
Write-Host "  4. Let the agent create hello.txt."
Write-Host "  5. Exit OpenCode normally when it is done."
Write-Host "  6. Keep recording: OCBox will show host integrity and the preserved patch."
Write-Host ""
Read-Host "Press ENTER to launch OCBox" | Out-Null

& $OpenScript -ProjectPath $DemoRoot
if (-not $?) {
    throw "The OCBox demo session did not complete successfully."
}

Write-Host ""
Write-Host "HOST AFTER" -ForegroundColor Cyan
$AfterHead = (& git -C $DemoRoot rev-parse HEAD).Trim()
& git -C $DemoRoot status -sb

if ($AfterHead -ne $Baseline) {
    throw "DEMO FAIL: host HEAD changed from $Baseline to $AfterHead"
}

$Porcelain = ((& git -C $DemoRoot status --porcelain) -join "`n").Trim()
if (-not [string]::IsNullOrWhiteSpace($Porcelain)) {
    throw "DEMO FAIL: host working tree changed:`n$Porcelain"
}

Write-Host "  PASS: host HEAD unchanged" -ForegroundColor Green
Write-Host "  PASS: host working tree clean" -ForegroundColor Green
Write-Host ""
Write-Host "PRESERVED AGENT OUTPUT" -ForegroundColor Cyan
& $ReviewScript -ProjectPath $DemoRoot

Write-Host ""
Write-Host "OCBOX DEMO: PASS" -ForegroundColor Green
Write-Host "The agent changed the sandbox clone; the Windows host checkout stayed untouched." -ForegroundColor Green
Write-Host "Demo repository kept at: $DemoRoot" -ForegroundColor DarkGray
Write-Host "Delete it manually after you finish recording." -ForegroundColor DarkGray
