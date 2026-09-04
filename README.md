# OCBox — OpenCode Local Sandbox

> Give a local coding agent broad freedom. Treat everything inside its workspace as potentially hostile.

OCBox is a Windows-first harness for running **OpenCode** inside a disposable **Docker Sandbox microVM**, backed by a **local llama.cpp server** on the Windows host.

The agent is intentionally powerful inside the sandbox: it can edit files, run shell commands, install packages, use `sudo`, build software, access public HTTP/HTTPS, and use a private Docker Engine. The Windows host is the asset OCBox tries to protect.

OCBox is **not** a malware-analysis lab, a DLP product, or a guarantee against sandbox/hypervisor zero-days. Read [SECURITY.md](SECURITY.md) before using it with sensitive code.

## What OCBox does

```text
Windows host
├── llama.cpp / llama-server.exe ── 127.0.0.1:<port>
├── your Git repository ─────────── host working tree remains untouched
│
└── Docker Sandbox microVM
    ├── private Git clone
    ├── OpenCode with no approval prompts
    ├── shell / sudo / package managers
    ├── private Docker Engine
    ├── public web on 80/443
    ├── private/LAN networks denied
    └── host services denied except llama.cpp
            │
            └─ on normal exit
               snapshot → verified Git bundle → refs/ocbox/* → destroy microVM
```

Agent output returns to the host as **passive Git objects** under `refs/ocbox/*`. OCBox does not automatically check out, execute, or merge the result.

## Status

OCBox is an experimental **v0.1 release candidate**. The current Windows reference setup has passed:

- host-isolation test: **12/12**
- disposable Git handoff test
- real OpenCode + local-model end-to-end workflow
- preservation of unstaged/untracked agent changes
- verified sandbox destruction with an unchanged host working tree

That is evidence that the intended controls are working in the tested environment, not a claim of perfect isolation.

## Requirements

OCBox itself does **not** vendor, build, download, or manage llama.cpp or model weights.

You need:

- Windows
- PowerShell 5.1 or PowerShell 7
- Git
- Docker Sandboxes CLI (`sbx`) and access to Docker Sandboxes
- an existing, working local `llama.cpp` checkout/build
- `llama-server.exe` at `llama.cpp\build\bin\Release\llama-server.exe`
- at least one `.gguf` model under `llama.cpp\models`

The model and llama.cpp performance tuning are intentionally outside OCBox's scope. OCBox only starts the configured local server and exposes that one loopback endpoint to the sandbox.

## Installation

Clone the repository:

```powershell
git clone https://github.com/lucatirel/opencode-local-sandbox.git
cd opencode-local-sandbox
```

If your PowerShell execution policy blocks local scripts, enable them for the current shell only:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
```

Run the bootstrap:

```powershell
.\sandbox.ps1 bootstrap
```

Bootstrap will:

1. check for the Docker Sandboxes CLI and offer to install it with `winget` when missing;
2. verify Git is available;
3. ask for your existing llama.cpp directory;
4. ask which GGUF model to use;
5. ask where new OCBox projects should be created;
6. write machine-specific values to ignored `config.local.ps1`;
7. run `doctor`.

`config.local.ps1` is intentionally not committed.

### Validate the installation

Run the complete local release gate:

```powershell
.\sandbox.ps1 validate
```

It runs:

- PowerShell syntax validation;
- versioned JSON validation;
- dependency-free functional tests;
- the host-isolation test;
- the disposable Git handoff test.

A successful run ends with:

```text
OCBOX VALIDATION: PASS
```

The GitHub-hosted CI intentionally runs only dependency-free/static checks. The microVM security and handoff tests must run on a machine with Docker Sandboxes.

## Usage

### Open an existing repository

The hardened workflow requires a Git repository with at least one commit.

```powershell
.\sandbox.ps1 open "C:\code\my-project"
```

OCBox will:

1. start the configured local llama-server if it is not already running;
2. create a disposable Docker Sandbox using clone mode;
3. apply and verify the effective network policy;
4. install an isolated OpenCode configuration;
5. attach you to OpenCode;
6. let the agent work in the private clone;
7. snapshot and export the result when OpenCode exits normally;
8. verify the host repository was not modified;
9. destroy the microVM only after successful handoff.

### Create a new project

```powershell
.\sandbox.ps1 new my-project
```

OCBox creates the directory, initializes Git, creates a minimal `README.md`, creates the initial commit required by clone mode, and opens the project.

The bootstrap commit uses an ephemeral `OCBox Bootstrap <ocbox@localhost>` identity and does not modify your global Git configuration.

### Review agent output

After a successful session:

```powershell
.\sandbox.ps1 review "C:\code\my-project"
```

This shows the latest OCBox snapshot and patch without checking it out or running it.

The snapshot is stored under a ref similar to:

```text
refs/ocbox/20260904-212416-08aa1848/snapshot
```

You can inspect it directly with Git:

```powershell
git -C "C:\code\my-project" for-each-ref refs/ocbox/
git -C "C:\code\my-project" diff HEAD..refs/ocbox/<session>/snapshot
git -C "C:\code\my-project" show refs/ocbox/<session>/snapshot:path/to/file
```

If you want a local review branch, create it **without checking it out**:

```powershell
git -C "C:\code\my-project" branch ocbox-review refs/ocbox/<session>/snapshot
```

Review the changes before executing or merging them.

### Recover a sandbox after a failed handoff

OCBox fails safe: if preservation cannot be verified, it leaves the sandbox alive instead of destroying it.

Recover it with:

```powershell
.\sandbox.ps1 handoff "C:\code\my-project"
```

### Other commands

```powershell
.\sandbox.ps1 doctor
.\sandbox.ps1 security-test
.\sandbox.ps1 handoff-test
.\sandbox.ps1 validate
.\sandbox.ps1 server
```

Run the launcher with no arguments to see built-in help:

```powershell
.\sandbox.ps1
```

## Configuration

Versioned defaults live in `config.example.ps1`. Machine-specific overrides belong in ignored `config.local.ps1`.

Typical local overrides:

```powershell
$LlamaRoot = 'C:\AI\llama.cpp'
$ModelFile = 'my-model.gguf'
$ProjectsRoot = 'C:\code'

# Optional model/server tuning:
$ContextSize = 16384
$OutputTokens = 2048
$SandboxMemory = '6g'
$SandboxCpus = 6
```

The llama.cpp launch tuning in `config.example.ps1` is a reference preset, not a universal hardware recommendation. Override it locally when your model or hardware requires different settings.

## Network model

The hardened default profile:

- allows public destinations on TCP ports 80 and 443;
- explicitly denies common private, LAN, VPN/overlay and link-local ranges;
- explicitly denies Windows localhost ports 80 and 443;
- relies on default deny for other network destinations/ports;
- adds one explicit host exception for `localhost:<LlamaPort>`;
- binds llama.cpp itself to `127.0.0.1`;
- exposes no host Docker socket;
- forwards no SSH agent;
- intentionally publishes no sandbox service ports.

OCBox checks the **effective** Docker Sandbox policy before launching OpenCode. If organization-level governance or another policy source changes the result, OCBox fails closed.

## Security model

The core assumption is simple:

> The coding agent, its dependencies, and everything it downloads may be hostile.

Compromise of the sandbox itself is therefore not considered a surprising event. The important boundary is what a fully compromised sandbox can reach on the host.

Run:

```powershell
.\sandbox.ps1 security-test
```

The current test verifies public web access, private-network denial, localhost denial and positive controls, host source read-only behavior, private-clone isolation, host-file isolation, SSH-agent isolation, and separation between the sandbox Docker Engine and the host Docker Engine.

See [SECURITY.md](SECURITY.md) for the threat model, source-confidentiality limitation, residual risk, and responsible reporting guidance.

## Important limitation: source exfiltration

A hostile process that can read your source code and reach arbitrary public HTTPS endpoints can exfiltrate that source **without escaping the sandbox**.

The default profile is designed primarily to protect:

- the wider Windows filesystem;
- host credentials;
- local services;
- the host Docker daemon;
- the private/LAN network;
- the checked-out host repository.

If source confidentiality is a hard requirement, use a strict outbound allowlist or an external DLP/inspection architecture instead of the default public-web profile.

## Repository layout

```text
sandbox.ps1                 command entry point
config.example.ps1          versioned defaults
scripts/
  bootstrap.ps1             machine bootstrap
  doctor.ps1                dependency/config checks
  validate.ps1              full local release gate
  open-project.ps1          hardened OpenCode lifecycle
  review-project.ps1        passive snapshot review
  handoff-project.ps1       recovery flow
  security-test.ps1         executable host-isolation checks
  handoff-test.ps1          executable Git lifecycle check
  private/
    Common.ps1              shared configuration/network/runtime helpers
    GitHandoff.ps1          snapshot/bundle/import/destruction logic
tests/
  static-tests.ps1          dependency-free regression checks
.github/workflows/
  validate.yml              hosted static CI
SECURITY.md                 threat model and residual risk
CONTRIBUTING.md             contributor workflow and release gate
```

## Development

Before submitting changes:

```powershell
.\sandbox.ps1 validate
```

Changes that weaken the network boundary, host isolation, Git handoff, or fail-safe destruction behavior should be treated as security-sensitive.

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT. See [LICENSE](LICENSE).
