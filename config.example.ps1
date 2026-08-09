# Defaults are loaded first; config.local.ps1 overrides only machine-specific values.

$LlamaRoot = "C:\path\to\llama.cpp"
$ModelFile = "Qwen3.6-35B-A3B-UD-Q3_K_M.gguf"
$ModelAlias = "qwen36-35b-q3"
$ModelDisplayName = "Qwen3.6 35B A3B Q3"

$ProjectsRoot = Join-Path $env:USERPROFILE "Projects"
$SandboxPrefix = "oc"
$SandboxMemory = "6g"
$SandboxCpus = 6

# Hardened agent profile.
# The agent gets full privileges and unrestricted HTTP/HTTPS inside the microVM,
# while the host repository is exposed read-only and work happens in a private clone.
$UseCloneMode = $true
$AllowFullWeb = $true
$DisableSharedSkills = $true
$DisableSshAgentForwarding = $true

# Keep work sandboxes after the agent exits until the safe Git handoff workflow is
# implemented. Security-test sandboxes are always disposable and removed automatically.
$DestroyWorkSandboxOnExit = $false

$LlamaPort = 8080
$ContextSize = 16384
$OutputTokens = 2048
$ServerStartupTimeoutSeconds = 120

# Tuned preset for RTX 4070 Laptop 8 GB + 16 GB system RAM.
$LoadMode = "mmap"
$CpuMoeLayers = 26
$GpuLayers = "all"
$Fit = "off"
$KvCacheType = "q4_0"
$BatchSize = 2048
$UBatchSize = 512
$CacheRamMiB = 0
$Parallel = 1

# OpenCode / generation defaults.
$Temperature = 0.6
$TopK = 20
$TopP = 0.95
$MinP = 0
$DisableThinking = $true

# Used only when $AllowFullWeb is $false. The local llama endpoint is always
# allowed automatically.
$AdditionalNetworkHosts = @()
