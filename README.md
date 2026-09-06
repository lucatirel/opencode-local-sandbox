# OCBox — OpenCode Local Sandbox

[![Validate](https://github.com/lucatirel/opencode-local-sandbox/actions/workflows/validate.yml/badge.svg)](https://github.com/lucatirel/opencode-local-sandbox/actions/workflows/validate.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform: Windows](https://img.shields.io/badge/platform-Windows-0078D4?logo=windows)](#requirements)
[![Docker Sandboxes](https://img.shields.io/badge/Docker%20Sandboxes-sbx-2496ED?logo=docker&logoColor=white)](https://docs.docker.com/ai/sandboxes/)
[![OpenCode](https://img.shields.io/badge/agent-OpenCode-111111)](https://opencode.ai/)

**A secure OpenCode sandbox for local LLM coding agents on Windows — Docker Sandboxes microVM isolation, llama.cpp integration, and verified Git-only handoff.**

OCBox is a Windows-first **OpenCode sandbox** for running an autonomous coding agent against a **local LLM** without giving that agent the same trust as the Windows host. It combines **OpenCode**, **llama.cpp**, and **Docker Sandboxes** so the agent can use shell access, `sudo`, package managers, builds, tests, Docker, and the public web inside a disposable microVM.

OpenCode works inside a private clone in the sandbox. Your local **llama.cpp / llama-server** stays on Windows. When the session ends, OCBox exports the agent's work through a verified Git bundle into passive `refs/ocbox/*` refs, verifies that the host working tree never changed, and only then destroys the sandbox.

> **Core idea:** trust the agent with the sandbox, not with the host.

**Designed for:** OpenCode sandboxing, local LLM coding agents, llama.cpp workflows, Windows AI development, Docker Sandboxes, coding-agent containment, and host-isolated autonomous development.

https://github.com/user-attachments/assets/3fd3e617-a81e-4da5-bfd9-56ac2351d64e

## Why this exists

Coding agents are most useful when you stop approving every command. That is also when mistakes, prompt injection, compromised dependencies, or over-eager automation can do the most damage.

OCBox moves the main boundary **below the agent** instead of relying on the agent to behave:

| The agent can | The agent should not get |
|---|---|
| edit its private Git clone | write access to your host working tree |
| run shell commands and `sudo` | arbitrary host filesystem access |
| install npm/pip/system packages | your host SSH agent |
| build and run tests | your host Docker socket |
| run its own private Docker Engine | GitHub/cloud credentials by default |
| access public HTTP/HTTPS | private/LAN/link-local services |
| call the configured local llama.cpp endpoint | arbitrary Windows localhost services |

The result comes back as **data to review**, not code that OCBox automatically checks out, merges, or executes.

## The 30-second model

```text
Windows host
├── llama.cpp / llama-server.exe ── 127.0.0.1:<port>
├── your Git repository ─────────── remains untouched
│
└── Docker Sandbox microVM
    ├── private writable Git clone
    ├── OpenCode with approval prompts disabled
    ├── shell / sudo / package managers
    ├── private Docker Engine
    ├── public web on 80/443
    ├── private/LAN networks denied
    └── host services denied except llama.cpp
            │
            └─ normal exit
               snapshot
                  ↓
               verified Git bundle
                  ↓
               passive refs/ocbox/* on host
                  ↓
               verify host HEAD + worktree unchanged
                  ↓
               destroy microVM
```

If preservation or verification fails, OCBox prefers to **leave the sandbox alive** rather than destroy work it cannot prove was safely exported.

## Quick start

### 1. Prerequisites

You need:

- Windows 11;
- PowerShell 5.1 or PowerShell 7;
- Git;
- Docker Sandboxes CLI (`sbx`) and access to Docker Sandboxes;
- an existing working `llama.cpp` Windows build;
- `llama-server.exe` at `llama.cpp\build\bin\Release\llama-server.exe`;
- at least one `.gguf` model under `llama.cpp\models`.

OCBox deliberately does **not** vendor model weights or manage your llama.cpp build.

### 2. Install OCBox

```powershell
git clone https://github.com/lucatirel/opencode-local-sandbox.git
cd opencode-local-sandbox
Set-ExecutionPolicy -Scope Process Bypass
.\sandbox.ps1 bootstrap
```

`bootstrap` checks the local tooling, asks for your existing llama.cpp directory and GGUF model, writes machine-specific settings to ignored `config.local.ps1`, and runs diagnostics.

### 3. Open a project

The project must already be a Git repository with at least one commit:

```powershell
.\sandbox.ps1 open "C:\code\my-project"
```

Or create a new one:

```powershell
.\sandbox.ps1 new my-project
```

Then use OpenCode normally. Inside the microVM it has broad local freedom.

### 4. Review what came back

After a successful session:

```powershell
.\sandbox.ps1 review "C:\code\my-project"
```

OCBox shows the latest preserved snapshot and patch **without checking it out or running it**.

## What OCBox adds on top of `sbx`

You can absolutely use Docker Sandboxes directly. OCBox is the opinionated workflow around it for this specific threat model and local-model setup.

| Concern | Raw `sbx` | OCBox workflow |
|---|---:|---:|
| disposable microVM | yes | yes |
| clone mode | configurable | required |
| host-local llama.cpp wiring | manual | automatic |
| private/LAN deny policy | manual | configured + verified |
| shared skills disabled | manual | required |
| SSH agent removed | manual | enforced/tested |
| host Docker separation | platform feature | regression-tested |
| preserve unstaged/untracked agent work | manual | automatic snapshot |
| verified bundle before import | manual | automatic |
| passive Git refs instead of checkout | manual | default |
| verify host HEAD/worktree unchanged | manual | automatic |
| fail-safe if handoff is uncertain | manual | default |
| executable isolation/adversarial tests | up to you | included |

OCBox is intentionally narrow: **OpenCode + local llama.cpp + Windows + Docker Sandboxes**. That narrowness lets the default path be explicit and testable instead of trying to be a generic agent platform.

## Evidence, not promises

On the Windows reference environment, the current release candidate has completed:

- **host isolation: PASS (12/12)**;
- **controlled adversarial containment: PASS (10/10)**;
- disposable Git handoff: PASS;
- real OpenCode + local-model end-to-end workflow;
- preservation of unstaged and untracked agent changes;
- host `HEAD` and working-tree integrity verification;
- sandbox destruction only after verified preservation.

Run the complete local release gate yourself:

```powershell
.\sandbox.ps1 validate
```

A successful run ends with:

```text
OCBOX VALIDATION: PASS
```

Run the credential/host/network/Docker containment probes separately with:

```powershell
.\sandbox.ps1 adversarial-test
```

A successful run ends with:

```text
ADVERSARIAL CONTAINMENT: PASS (10/10)
```

These are regression tests for the tested environment, **not proof that sandbox or hypervisor vulnerabilities cannot exist**.

## Security model

The core assumption is intentionally pessimistic:

> **The coding agent, its dependencies, and everything it downloads may be hostile.**

The hardened default profile uses:

- Docker Sandboxes clone mode;
- a private writable clone for agent work;
- a read-only host source view at the sandbox boundary;
- no shared host skills;
- no forwarded SSH agent;
- no host Docker socket;
- no intentionally published sandbox ports;
- public wildcard access restricted to TCP 80/443;
- explicit denies for common private/LAN/link-local ranges;
- default deny for unmatched network destinations/ports;
- one explicit host-service exception for the configured llama.cpp loopback port;
- effective-policy verification before OpenCode starts;
- passive Git handoff under `refs/ocbox/*`;
- host integrity verification before destruction.

### Important limitation: source exfiltration

If a hostile sandbox can read source code **and** reach arbitrary public HTTPS destinations, it can potentially exfiltrate that source without escaping the microVM.

OCBox is therefore **not DLP**. For confidential source where outbound exfiltration is unacceptable, use a much tighter egress allowlist or a dedicated inspected environment.

See [SECURITY.md](SECURITY.md) for the full threat model, residual risks, untrusted-output guidance, and vulnerability-reporting policy.

## Git handoff: why passive refs?

Agent output is imported under a ref similar to:

```text
refs/ocbox/20260904-212416-08aa1848/snapshot
```

Nothing is automatically checked out or merged.

Inspect it directly:

```powershell
git -C "C:\code\my-project" for-each-ref refs/ocbox/
git -C "C:\code\my-project" diff HEAD..refs/ocbox/<session>/snapshot
git -C "C:\code\my-project" show refs/ocbox/<session>/snapshot:path/to/file
```

If you want a local review branch, create it without checking it out:

```powershell
git -C "C:\code\my-project" branch ocbox-review refs/ocbox/<session>/snapshot
```

Treat the result like an untrusted pull request: review CI workflows, package scripts, build files, hooks, editor tasks, container definitions, installers, and generated binaries before executing anything.

## Failure recovery

OCBox is fail-safe around preservation. If it cannot verify the snapshot/bundle/copy/import sequence, the sandbox is intentionally left alive.

Recover later with:

```powershell
.\sandbox.ps1 handoff "C:\code\my-project"
```

Automatic destruction is also blocked for repository states that currently need dedicated preservation handling, including Git LFS content, multiple worktrees, ignored files, and dirty/diverged submodules.

## Commands

```text
.\sandbox.ps1 bootstrap                  configure this PC
.\sandbox.ps1 doctor                     check local dependencies/config
.\sandbox.ps1 open C:\code\project       open an existing Git project
.\sandbox.ps1 new my-project             create and open a Git project
.\sandbox.ps1 review C:\code\project     inspect the latest snapshot safely
.\sandbox.ps1 handoff C:\code\project    recover a preserved sandbox
.\sandbox.ps1 validate                   full local release gate
.\sandbox.ps1 security-test              host-isolation checks
.\sandbox.ps1 adversarial-test           credential/network/host probes
.\sandbox.ps1 cleanup                    remove stale disposable test sandboxes
.\sandbox.ps1 prepublish-audit           audit reachable Git history before release
.\sandbox.ps1 server                     run llama-server manually
```

Run `./sandbox.ps1` with no command to show built-in help.

## Configuration

Versioned defaults live in `config.example.ps1`. Machine-specific overrides belong in ignored `config.local.ps1`.

Typical local overrides:

```powershell
$LlamaRoot = 'C:\AI\llama.cpp'
$ModelFile = 'my-model.gguf'
$ProjectsRoot = 'C:\code'

# Optional model/server tuning
$ContextSize = 16384
$OutputTokens = 2048
$SandboxMemory = '6g'
$SandboxCpus = 6
```

The llama.cpp launch tuning in `config.example.ps1` is a reference preset, not a universal hardware recommendation.

## Who this is for

OCBox is a good fit if you:

- use OpenCode with a local llama.cpp model on Windows;
- want the agent to work with few or no approval interruptions;
- care more about protecting the host than keeping the sandbox pristine;
- want the host repository unchanged until you explicitly review the result;
- are comfortable treating agent output as untrusted code.

It is **not** intended as:

- a malware detonation lab;
- a guarantee against Docker Sandbox/microVM/hypervisor zero-days;
- a source-code DLP product;
- a generic cross-platform agent orchestration framework.

## Roadmap

See [ROADMAP.md](ROADMAP.md) for the public roadmap. The immediate focus is keeping the host boundary explicit, testable, and boring before broadening backend or platform support.

## Contributing

Issues and pull requests are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md) first: changes that weaken the host boundary or passive handoff model need corresponding reasoning and regression coverage.

## License

MIT. See [LICENSE](LICENSE).
