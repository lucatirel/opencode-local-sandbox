function Resolve-LlamaModelPath {
    param([Parameter(Mandatory = $true)]$Config)
    if ([IO.Path]::IsPathRooted($Config.ModelFile)) { return [IO.Path]::GetFullPath($Config.ModelFile) }
    $Directory = $Config.ModelsDirectory
    if ([string]::IsNullOrWhiteSpace($Directory)) { $Directory = Join-Path $Config.LlamaRoot 'models' }
    return [IO.Path]::GetFullPath((Join-Path $Directory $Config.ModelFile))
}

function Read-LlamaPresets {
    param([Parameter(Mandatory = $true)][string]$Path)
    $Sections = [ordered]@{}
    $Section = $null
    foreach ($Line in Get-Content -LiteralPath $Path) {
        if ($Line -match '^\s*\[([^\]]+)\]\s*$') {
            $Section = $Matches[1]
            if (-not $Sections.Contains($Section)) { $Sections[$Section] = @{} }
        }
        elseif ($null -ne $Section -and $Line -match '^\s*([^;#=]+?)\s*=\s*(.*?)\s*$') {
            $Sections[$Section][$Matches[1].Trim()] = $Matches[2].Trim().Trim('"')
        }
    }
    foreach ($Alias in $Sections.Keys) {
        if ($Alias -eq '*') { continue }
        $Values = @{}
        if ($Sections.Contains('*')) { foreach ($Key in $Sections['*'].Keys) { $Values[$Key] = $Sections['*'][$Key] } }
        foreach ($Key in $Sections[$Alias].Keys) { $Values[$Key] = $Sections[$Alias][$Key] }
        if (-not $Values.ContainsKey('model')) { continue }
        $Context = 16384
        foreach ($Key in @('c', 'ctx-size')) {
            if ($Values.ContainsKey($Key)) {
                $Parsed = 0
                if (-not [int]::TryParse($Values[$Key], [ref]$Parsed) -or $Parsed -lt 1) { throw "Set an explicit positive context for preset [$Alias] in $Path." }
                $Context = $Parsed
                break
            }
        }
        [pscustomobject]@{ Alias = $Alias; ContextSize = $Context; ModelFile = $Values['model'] }
    }
}

function Get-LlamaApiModels {
    param([int]$Port = 8080)
    $Document = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/v1/models" -TimeoutSec 5 -ErrorAction Stop
    if (-not $Document.PSObject.Properties['data']) { throw 'The local endpoint did not return an OpenAI-compatible model list.' }
    return @($Document.data | Where-Object { $_.PSObject.Properties['id'] -and $_.id } | ForEach-Object { [string]$_.id })
}

function Assert-LlamaModelAvailable {
    param([Parameter(Mandatory = $true)]$Config)
    $Aliases = @(Get-LlamaApiModels -Port $Config.LlamaPort)
    if ($Aliases -notcontains $Config.ModelAlias) {
        throw "Configured model '$($Config.ModelAlias)' is not advertised by the local server. Available: $($Aliases -join ', '). Run .\sandbox.ps1 bootstrap -ModelAlias <alias>."
    }
}

function Initialize-OcboxModelConfig {
    param([string]$LlamaRoot, [string]$ModelFile, [string]$ProjectsRoot, [string]$ModelAlias, [string]$ModelsPreset, [string]$ServerMode)
    $LocalFile = Join-Path (Get-ToolRoot) 'config.local.ps1'
    $Existing = Test-Path -LiteralPath $LocalFile
    $Current = $null
    $Source = ''
    if ($Existing) {
        $Source = Get-Content -LiteralPath $LocalFile -Raw
        $Current = Get-ToolConfig
        if (-not $LlamaRoot) { $LlamaRoot = $Current.LlamaRoot }
        if (-not $ProjectsRoot) { $ProjectsRoot = $Current.ProjectsRoot }
        if (-not $ModelAlias -and $Current.ModelAlias -ne 'local-model') { $ModelAlias = $Current.ModelAlias }
        if (-not $ModelsPreset) { $ModelsPreset = $Current.ModelsPreset }
        if (-not $ServerMode -and $Source -match '(?m)^\s*\$ServerMode\s*=') { $ServerMode = $Current.ServerMode }
        # Preserve an explicitly configured legacy single-model setup.
        if (-not $ServerMode -and -not $ModelsPreset -and $Source -match '(?m)^\s*\$ModelFile\s*=') {
            $ServerMode = 'single'
        }
    }

    if (-not $LlamaRoot -or -not (Test-Path -LiteralPath $LlamaRoot -PathType Container)) {
        $Candidates = @((Join-Path (Split-Path (Get-ToolRoot) -Parent) 'llama.cpp'), (Join-Path $env:USERPROFILE 'Desktop\git\llama.cpp'), (Join-Path $env:USERPROFILE 'llama.cpp'))
        $LlamaRoot = @($Candidates | Where-Object { Test-Path -LiteralPath (Join-Path $_ 'build\bin\Release\llama-server.exe') }) | Select-Object -First 1
    }
    if (-not $ModelsPreset -and $LlamaRoot -and (-not $ServerMode -or $ServerMode -eq 'router')) {
        $Presets = @(Get-ChildItem -LiteralPath $LlamaRoot -Filter '*models*.ini' -File | Sort-Object Name)
        if ($Presets.Count -eq 1) { $ModelsPreset = $Presets[0].FullName }
        elseif ($Presets.Count -gt 1) { $ModelsPreset = Read-Host 'Multiple model presets found; enter the full preset INI path' }
    }
    $Port = 8080
    if ($Current) { $Port = $Current.LlamaPort }
    $ApiAliases = @()
    try { $ApiAliases = @(Get-LlamaApiModels -Port $Port) } catch { }
    if (-not $ServerMode) {
        $ServerMode = if ($ModelsPreset) { 'router' } elseif ($ApiAliases.Count -gt 0) { 'external' } else { 'single' }
    }
    $Catalog = @()
    if ($ServerMode -eq 'router') {
        if (-not $ModelsPreset) { $ModelsPreset = Read-Host 'Full path of your llama.cpp models preset INI' }
        $ModelsPreset = (Resolve-Path -LiteralPath $ModelsPreset).Path
        $Catalog = @(Read-LlamaPresets -Path $ModelsPreset)
        if ($Catalog.Count -eq 0) { throw "No model presets found in $ModelsPreset" }
    }
    elseif ($ServerMode -eq 'external') {
        if ($ApiAliases.Count -eq 0) { throw "Start your local server/router on port $Port, then rerun bootstrap." }
        $Catalog = @($ApiAliases | ForEach-Object { [pscustomobject]@{ Alias = $_; ContextSize = 16384 } })
    }
    if ($Catalog.Count -gt 0) {
        if (-not $ModelAlias -or @($Catalog.Alias) -notcontains $ModelAlias) {
            for ($Index = 0; $Index -lt $Catalog.Count; $Index++) { Write-Host ("  {0}. {1} (context {2})" -f ($Index + 1), $Catalog[$Index].Alias, $Catalog[$Index].ContextSize) }
            $Choice = Read-Host 'Default model: enter alias or number [1]'
            if (-not $Choice) { $Choice = '1' }
            $Number = 0
            if ([int]::TryParse($Choice, [ref]$Number) -and $Number -ge 1 -and $Number -le $Catalog.Count) { $ModelAlias = $Catalog[$Number - 1].Alias }
            else { $ModelAlias = $Choice }
        }
        $Selected = @($Catalog | Where-Object { $_.Alias -eq $ModelAlias })
        if ($Selected.Count -ne 1) { throw "Unknown model alias: $ModelAlias" }
        $Context = $Selected[0].ContextSize
    }
    else {
        if (-not $LlamaRoot) { $LlamaRoot = Read-Host 'Full path of your existing llama.cpp directory' }
        $Directory = Join-Path $env:USERPROFILE 'LocalAI\models'
        if ($Current) { $Directory = $Current.ModelsDirectory }
        if (-not $Directory -or -not (Test-Path -LiteralPath $Directory)) { $Directory = Join-Path $LlamaRoot 'models' }
        if (-not $ModelFile -and $Current) { $ModelFile = Resolve-LlamaModelPath -Config $Current }
        if (-not $ModelFile) {
            Write-Host "GGUF directory: $Directory"
            Get-ChildItem -LiteralPath $Directory -Filter '*.gguf' -File | Select-Object -ExpandProperty Name | ForEach-Object { Write-Host "  $_" }
            $ModelFile = Read-Host 'GGUF filename or absolute path'
        }
        if (-not [IO.Path]::IsPathRooted($ModelFile)) { $ModelFile = Join-Path $Directory $ModelFile }
        $ModelFile = (Resolve-Path -LiteralPath $ModelFile).Path
        if (-not $ModelAlias) { $ModelAlias = 'local-model' }
        $Context = if ($Current) { $Current.ContextSize } else { 16384 }
    }
    if (-not $ProjectsRoot) { $ProjectsRoot = Join-Path $env:USERPROFILE 'Projects' }
    New-Item -ItemType Directory -Force -Path $ProjectsRoot | Out-Null
    $Updates = [ordered]@{ ServerMode = $ServerMode; ModelAlias = $ModelAlias; ModelDisplayName = $ModelAlias; ProjectsRoot = $ProjectsRoot }
    if ($LlamaRoot) { $Updates['LlamaRoot'] = $LlamaRoot }
    if ($ModelsPreset) { $Updates['ModelsPreset'] = $ModelsPreset }
    if ($ModelFile) { $Updates['ModelFile'] = $ModelFile; $Updates['ModelsDirectory'] = Split-Path $ModelFile -Parent }
    # Preserve a smaller user limit, but never advertise more than the selected preset.
    if (-not $Existing) { $Updates['ContextSize'] = [int]$Context }
    elseif ($ServerMode -eq 'router') { $Updates['ContextSize'] = [Math]::Min([int]$Current.ContextSize, [int]$Context) }
    $Lines = @('# OCBox managed settings (machine-local; gitignored).')
    foreach ($Key in $Updates.Keys) {
        $Value = $Updates[$Key]
        if ($Value -is [int]) { $Lines += ('$' + $Key + ' = ' + $Value) }
        else { $Lines += ('$' + $Key + " = '" + ([string]$Value).Replace("'", "''") + "'") }
    }
    if ($Existing) { Copy-Item -LiteralPath $LocalFile -Destination ($LocalFile + '.pre-repo.bak') -Force }
    # Replace only the managed block; retain user-defined tuning outside it.
    $Source = [regex]::Replace($Source, '(?ms)^# BEGIN OCBOX MANAGED\r?\n.*?^# END OCBOX MANAGED\r?\n?', '')
    $Source.TrimEnd() + "`r`n# BEGIN OCBOX MANAGED`r`n" + ($Lines -join "`r`n") + "`r`n# END OCBOX MANAGED`r`n" | Set-Content -LiteralPath $LocalFile -Encoding UTF8
    Write-Host "Local configuration ready: $ServerMode / $ModelAlias" -ForegroundColor Green
}
