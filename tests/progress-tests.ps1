$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../scripts/private/Common.ps1')
$Exe = Join-Path $PSHOME $(if ($PSVersionTable.PSEdition -eq 'Desktop') { 'powershell.exe' } elseif ($env:OS -eq 'Windows_NT') { 'pwsh.exe' } else { 'pwsh' })
Invoke-ExternalProgress $Exe @('-NoLogo', '-NoProfile', '-Command', '[Console]::Error.WriteLine("OCBOX_NATIVE_STDERR"); exit 0') -Activity 'Progress regression: successful native stderr'
$Observed = $false
try {
    Invoke-ExternalProgress $Exe @('-NoLogo', '-NoProfile', '-Command', '[Console]::Error.WriteLine("OCBOX_ORIGINAL_FAILURE"); exit 7') -Activity 'Progress regression: failed native command'
}
catch {
    $Observed = $_.Exception.Message -match 'exit 7' -and $_.Exception.Message -match 'OCBOX_ORIGINAL_FAILURE'
}
if (-not $Observed) { throw 'Progress must retain the original native error and non-zero exit code.' }
$Observed = $false
try {
    Invoke-ExternalProgress $Exe @('-NoLogo', '-NoProfile', '-Command', 'Start-Sleep -Seconds 10') -Activity 'Progress regression: timeout' -TimeoutSeconds 1
}
catch { $Observed = $_.Exception.Message -match 'Timed out' }
if (-not $Observed) { throw 'A hung native operation must time out with an actionable diagnostic.' }
$global:LASTEXITCODE = 0
Write-Host 'Native progress/error/timeout regression tests passed.' -ForegroundColor Green
