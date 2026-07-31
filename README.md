# OpenCode + Qwen3 + llama.cpp in a Docker Sandbox

Reproducible Windows setup for running Qwen3 locally through `llama.cpp`, using OpenCode inside an isolated Docker Sandbox.

## Architecture

- `llama-server` runs on the Windows host.
- The server listens only on `127.0.0.1:8080`.
- OpenCode runs inside the Docker Sandbox.
- The sandbox reaches the host through `host.docker.internal`.
- HTTPS is enabled with a local development certificate.
- CORS is limited to localhost.
- The llama.cpp Web UI is disabled.
- Models, private keys and machine-specific paths are not committed.

## Tested configuration

- Windows 11
- NVIDIA RTX 4070 Laptop GPU, 8 GB VRAM
- 16 GB system RAM
- OpenCode 1.17.11
- Qwen3 8B Q4_K_M
- Context: 32768
- KV cache: Q4
- Flash Attention: enabled
- One inference slot

## Repository contents

```text
.
|-- opencode.json
|-- config.example.ps1
|-- scripts
|   |-- generate-certs.ps1
|   |-- setup-sandbox.ps1
|   |-- start-llama.ps1
|   `-- run-opencode.ps1
|-- .gitignore
`-- README.md
```

The following files are intentionally excluded from Git:

- `config.local.ps1`
- GGUF models
- compiled llama.cpp binaries
- private keys
- local certificates
- temporary files and logs

## Requirements

Install the following tools before using the project:

- Git
- Docker Desktop
- Docker Sandboxes CLI
- PowerShell
- llama.cpp compiled with CUDA support
- mkcert
- OpenCode sandbox image

Install mkcert with:

```powershell
winget install -e --id FiloSottile.mkcert
```

## Clone the repository

```powershell
git clone YOUR_REPOSITORY_URL
Set-Location YOUR_REPOSITORY_FOLDER
```

## Create the local configuration

Copy the example configuration:

```powershell
Copy-Item ".\config.example.ps1" ".\config.local.ps1"
```

Open it:

```powershell
notepad ".\config.local.ps1"
```

Configure the llama.cpp path and model filename:

```powershell
$LlamaRoot = "C:\Users\YOUR_USER\Desktop\Git\llama.cpp"
$ModelFile = "Qwen3-8B-Q4_K_M.gguf"
```

The model must be located at:

```text
C:\path\to\llama.cpp\models\Qwen3-8B-Q4_K_M.gguf
```

The compiled server must be located at:

```text
C:\path\to\llama.cpp\build\bin\Release\llama-server.exe
```

## Generate HTTPS certificates

Run:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\scripts\generate-certs.ps1
```

The certificates will be created in:

```text
llama.cpp\certs\
```

The certificate includes:

- `localhost`
- `127.0.0.1`
- `::1`
- `host.docker.internal`

## Configure the Docker Sandbox

Run:

```powershell
.\scripts\setup-sandbox.ps1
```

This script:

1. Creates the OpenCode sandbox if it does not already exist.
2. Applies the configured RAM and CPU limits.
3. Allows access to the local llama.cpp endpoint.
4. Copies the mkcert root CA into the sandbox.
5. Installs the CA in the sandbox trust store.

## Start llama.cpp

Open a PowerShell terminal in the repository and run:

```powershell
.\scripts\start-llama.ps1
```

Keep this terminal open while using OpenCode.

The API endpoint will be:

```text
https://127.0.0.1:8080/v1
```

Inside the sandbox, OpenCode uses:

```text
https://host.docker.internal:8080/v1
```

## Start OpenCode

Open a second PowerShell terminal in the repository and run:

```powershell
.\scripts\run-opencode.ps1
```

## Verify the llama.cpp API

From Windows PowerShell:

```powershell
Invoke-RestMethod `
    -Uri "https://localhost:8080/v1/models" `
    -Method Get
```

To test chat completions:

```powershell
$Body = @{
    model = "qwen3-8b-q4"
    messages = @(
        @{
            role = "user"
            content = "Reply with exactly: hello"
        }
    )
} | ConvertTo-Json -Depth 10

Invoke-RestMethod `
    -Uri "https://localhost:8080/v1/chat/completions" `
    -Method Post `
    -ContentType "application/json" `
    -Body $Body
```

## Normal startup workflow

Terminal 1:

```powershell
Set-Location "C:\path\to\repository"
.\scripts\start-llama.ps1
```

Terminal 2:

```powershell
Set-Location "C:\path\to\repository"
.\scripts\run-opencode.ps1
```

## Security notes

- The llama.cpp server listens only on `127.0.0.1`.
- The server is not exposed to the local network.
- HTTPS uses a locally trusted mkcert certificate.
- The private key remains outside the repository.
- The GGUF model remains outside the repository.
- Machine-specific paths remain in `config.local.ps1`.
- OpenCode executes inside a resource-limited Docker Sandbox.
- Repository permissions are currently configured as `allow`.

Review `opencode.json` before using the project with untrusted repositories.

## Troubleshooting

### PowerShell blocks script execution

Run:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
```

### llama-server executable not found

Verify this path in `config.local.ps1`:

```text
$LlamaRoot\build\bin\Release\llama-server.exe
```

### Model not found

Verify that the model exists at:

```text
$LlamaRoot\models\$ModelFile
```

### HTTPS certificate errors

Regenerate the certificates:

```powershell
.\scripts\generate-certs.ps1
```

Then reinstall the CA inside the sandbox:

```powershell
.\scripts\setup-sandbox.ps1
```

### Sandbox cannot reach llama.cpp

Verify that llama.cpp is running and inspect the sandbox policy:

```powershell
sbx policy log agentbox-test --limit 20
```

The allowed requests should include:

```text
localhost:8080
```

### OpenCode shows empty think tags

The llama.cpp startup script sets:

```text
LLAMA_ARG_CHAT_TEMPLATE_KWARGS={"enable_thinking":false}
```

The server also uses the configured reasoning format for compatibility with OpenCode.
