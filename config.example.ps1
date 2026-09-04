# Versioned defaults. Machine-specific settings belong in config.local.ps1.
#
# llama.cpp and model weights are external dependencies. OCBox does not download,
# build, vendor or tune them automatically.

$LlamaRoot = "C:\path\to\llama.cpp"
$ModelFile = "model.gguf"
$ModelAlias = "local-model"
$ModelDisplayName = "Local GGUF model"

$ProjectsRoot = Join-Path $env:USERPROFILE "Projects"
$SandboxPrefix = "oc"
$SandboxMemory = "6g"
$SandboxCpus = 6

# Hardened agent profile.
# The agent gets broad privileges inside the microVM while the host repository is
# not its writable working copy.
$UseCloneMode = $true
$AllowFullWeb = $true
$DisableSharedSkills = $true
$DisableSshAgentForwarding = $true

# Verified lifecycle: after OpenCode exits normally, snapshot the private clone,
# import it into passive refs/ocbox/* refs on the host, verify host HEAD/status are
# unchanged, and only then destroy the work sandbox. Preservation uncertainty
# intentionally keeps the sandbox alive.
$DestroyWorkSandboxOnExit = $true

$LlamaPort = 8080
$ContextSize = 16384
$OutputTokens = 2048
$ServerStartupTimeoutSeconds = 120

# Reference llama.cpp launch preset.
# These values are hardware/model specific and are NOT part of OCBox's security
# model. Override them in config.local.ps1 when your llama.cpp/model setup needs
# different tuning.
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
