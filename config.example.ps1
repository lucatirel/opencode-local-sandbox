# Defaults are loaded first; config.local.ps1 overrides only machine-specific values.

$LlamaRoot = "C:\path\to\llama.cpp"
$ModelFile = "Qwen3-8B-Q4_K_M.gguf"
$ModelAlias = "qwen3-8b-q4"
$ModelDisplayName = "Qwen3 8B Q4_K_M"

$ProjectsRoot = Join-Path $env:USERPROFILE "Projects"
$SandboxPrefix = "oc"
$SandboxMemory = "6g"
$SandboxCpus = 6

$LlamaPort = 8080
$ContextSize = 32768
$OutputTokens = 2048
$ServerStartupTimeoutSeconds = 120

$GpuLayers = "all"
$KvCacheType = "q4_0"
$Temperature = 0.6
$TopK = 20
$TopP = 0.95
$MinP = 0
$ReasoningFormat = "deepseek"
$DisableThinking = $true

$OpenCodePermission = "allow"

# These rules are added only to each project sandbox. The local llama endpoint
# is always added automatically. Keep this empty for the smallest allow-list.
# Example: @("registry.npmjs.org:443", "pypi.org:443", "files.pythonhosted.org:443")
$AdditionalNetworkHosts = @()

