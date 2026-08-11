# OCBox — OpenCode Local Sandbox

> **Give your local coding agent freedom. Treat it like it's hostile.**

OCBox is a Windows-first harness for running **OpenCode + a local llama.cpp model** inside a disposable Docker Sandbox microVM.

The agent gets broad freedom *inside* the sandbox: shell, installs, sudo, package managers, its own Docker Engine, public HTTP/HTTPS, and no approval prompts. The Windows host is treated as the asset to protect.

```text
Windows host
├── llama.cpp  ─────────────── 127.0.0.1:8080 only
├── your Git repo ──────────── host working tree stays untouched
│
└── Docker Sandbox microVM
    ├── private Git clone
    ├── OpenCode: full autonomy
    ├── public web: 80/443
    ├── LAN/private ranges: denied
    ├── host services: denied except llama port
    └── disposable lifecycle
            ↓
       Git snapshot
            ↓
       verified Git bundle
            ↓
       refs/ocbox/* on host
            ↓
       microVM destroyed
```

The result comes back as **passive Git objects**, not as an automatic checkout or merge.

## The 20-second version

Once configured:

```powershell
.\sandbox.ps1 open "C:\code\my-project"
```

Work with OpenCode normally. When you exit OpenCode successfully, OCBox:

1. snapshots the private clone inside the microVM;
2. creates a Git bundle inside the sandbox;
3. copies and verifies the bundle on the host;
4. imports it under `refs/ocbox/...`;
5. verifies host `HEAD` and working-tree status did not change;
6. destroys the microVM.

Review the result without checking it out:

```powershell
.\sandbox.ps1 review "C:\code\my-project"
```

That is the core workflow.

## Why this exists

Coding agents are most useful when they can actually act: run commands, install dependencies, test things, create files, use tools and iterate without waiting for approval every 30 seconds.

That is also exactly what makes an agent dangerous if it consumes malicious instructions or malicious dependencies.

OCBox moves the trust boundary outward:

- **inside the sandbox:** assume compromise is acceptable;
- **outside the sandbox:** make host access explicit, narrow and testable.

The project is intentionally built around executable security checks rather than a "trust the setup" claim.

## Security posture

The hardened default profile uses:

- Docker Sandboxes clone mode;
- `--no-share-skills`;
- no SSH agent forwarding;
- no host Docker socket;
- no intentionally published sandbox ports;
- OpenCode `permission: { "*": "allow" }` inside the microVM;
- llama.cpp bound to host `127.0.0.1` only;
- one explicit host exception: `localhost:<llama-port>`;
- public HTTP/HTTPS wildcard access on ports 80/443;
- explicit denies for localhost 80/443;
- explicit denies for common LAN, VPN/overlay and link-local ranges;
- default deny for other network destinations/ports;
- disposable microVMs after verified Git handoff.

### Why not `allow **`?

Because we tested it.

An unrestricted Docker Sandbox network wildcard also made arbitrary Windows localhost HTTP services reachable through `host.docker.internal` in our environment. OCBox therefore never uses a bare `allow **` in the hardened profile.

Run the isolation test yourself:

```powershell
.\sandbox.ps1 security-test
```

The test includes both negative and positive controls so a PASS is not simply "the test couldn't connect to anything".

See [SECURITY.md](SECURITY.md) for the threat model, residual risks and the important source-exfiltration limitation.

## Git handoff: untrusted code stays untrusted

Agent output is treated like an untrusted pull request.

A successful session lands at a ref such as:

```text
refs/ocbox/20260811-201336-f2271e34/snapshot
```

Your checked-out branch and working tree are not modified.

Inspect the latest result:

```powershell
.\sandbox.ps1 review "C:\code\my-project"
```

Or use normal Git directly:

```powershell
git -C "C:\code\my-project" for-each-ref refs/ocbox/
git -C "C:\code\my-project" diff HEAD..refs/ocbox/<session>/snapshot
git -C "C:\code\my-project" show refs/ocbox/<session>/snapshot:path/to/file
```

If you want a local branch for deeper review **without checkout**:

```powershell
git -C "C:\code\my-project" branch ocbox-review refs/ocbox/<session>/snapshot
```

Review before executing or merging it.

## Fail safe, not fail destructive

If snapshot, bundle creation, copy, verification or import fails, OCBox does **not** destroy the sandbox.

Recover a preserved sandbox later with:

```powershell
.\sandbox.ps1 handoff "C:\code\my-project"
```

Only a verified handoff is followed by `sbx rm`.

Files ignored by Git are another deliberate stop condition: if the agent created ignored files that would be lost by `git add -A`, automatic destruction is refused.

## Requirements

Current target environment:

- Windows + PowerShell;
- Git;
- Docker Sandboxes CLI (`sbx`);
- a working local `llama.cpp` build with `llama-server.exe`;
- at least one GGUF model in `llama.cpp\models`.

OCBox does **not** download a model or build llama.cpp for you. Hardware/model choice is machine-specific.

## Install

Clone the repository:

```powershell
git clone https://github.com/lucatirel/opencode-local-sandbox.git
cd opencode-local-sandbox
Set-ExecutionPolicy -Scope Process Bypass
```

Bootstrap the machine:

```powershell
.\sandbox.ps1 bootstrap
```

The bootstrap can install the Docker Sandboxes CLI with `winget`, asks for your llama.cpp/model/project paths, creates an ignored `config.local.ps1`, and runs `doctor`.

Then verify the security boundary on your machine:

```powershell
.\sandbox.ps1 security-test
.\sandbox.ps1 handoff-test
```

Do this before trusting the hardened profile on a new machine or after meaningful Docker Sandboxes policy changes.

## Everyday commands

```powershell
# Open an existing Git repository in a disposable private clone
.\sandbox.ps1 open "C:\code\my-project"

# Review the newest agent result without checkout
.\sandbox.ps1 review "C:\code\my-project"

# Recover a sandbox preserved after a failed automatic handoff
.\sandbox.ps1 handoff "C:\code\my-project"

# Create a new project
.\sandbox.ps1 new "my-project"

# Validate local dependencies/config
.\sandbox.ps1 doctor

# Run host-isolation tests
.\sandbox.ps1 security-test

# Run the disposable Git lifecycle test
.\sandbox.ps1 handoff-test

# Start llama.cpp manually instead of auto-starting it
.\sandbox.ps1 server
```

## A good first agent prompt

After `open`, try:

```text
Inspect this repository first. Then implement one small, self-contained improvement.
Run the relevant tests or validation available inside the environment.
Do not push to any remote. When finished, summarize exactly which files changed,
which commands/tests you ran, and any unresolved risks.
```

OCBox does not depend on the model behaving safely; this is simply a useful functional test of the workflow.

## Configuration

`config.example.ps1` contains versioned defaults. `config.local.ps1` is ignored and should contain only machine-specific overrides, for example:

```powershell
$LlamaRoot = 'C:\AI\llama.cpp'
$ModelFile = 'my-model.gguf'
$ProjectsRoot = 'C:\code'
```

The current performance preset is just a default, not part of the security model. Tune model/context/batching to your hardware.

Important security settings are versioned and validated by `doctor` and the executable tests.

## Network model

The default profile allows broad **public web traffic on standard HTTP/HTTPS ports 80 and 443**. It is not arbitrary-port Internet access.

The llama endpoint is separately allowed as a specific host-local exception. Ports 80 and 443 are intentionally invalid choices for the llama port in the hardened profile because localhost 80/443 are explicitly denied.

If public web access is disabled, `AdditionalNetworkHosts` can be used for an explicit allowlist.

## What this does *not* guarantee

OCBox is defense in depth, not mathematically perfect isolation.

It does not protect source confidentiality from a hostile process that can both read your source and access the public Internet. Full web access means a compromised sandbox could exfiltrate source code. Use restrictive egress/DLP for that threat model.

It also cannot eliminate vulnerabilities in the microVM/hypervisor, Docker Sandboxes, its proxy/policy engine, Windows, Git parsing or other trusted host components.

## Project layout

```text
.
├── sandbox.ps1                 # public CLI
├── config.example.ps1          # versioned defaults
├── SECURITY.md
├── LICENSE
├── scripts/
│   ├── bootstrap.ps1
│   ├── doctor.ps1
│   ├── open-project.ps1
│   ├── review-project.ps1
│   ├── handoff-project.ps1
│   ├── security-test.ps1
│   ├── handoff-test.ps1
│   ├── start-llama.ps1
│   └── private/
│       ├── Common.ps1
│       └── GitHandoff.ps1
├── tests/
│   └── static-tests.ps1
└── .github/workflows/validate.yml
```

## Status

OCBox is early-stage and Windows-focused. The security model is deliberately narrow: local OpenCode + local llama.cpp + Docker Sandboxes + Git-based disposable handoff.

If you try it on another machine, run the executable tests and report differences rather than assuming the policy behaves identically.

## License

MIT.
