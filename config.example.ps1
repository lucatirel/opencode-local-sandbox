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