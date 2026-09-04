# Security model

OCBox is built around one assumption:

> **The coding agent, its dependencies, and everything it downloads may be hostile.**

The goal is not to make OpenCode less capable. The goal is to give it broad freedom inside a disposable Docker Sandbox microVM while minimizing what that environment can reach on the Windows host.

This is defense in depth, not a claim of perfect isolation.

## Security objective

The agent is intentionally trusted with the sandbox and **not** trusted with the host.

Inside the microVM it may:

- edit the private clone;
- run arbitrary shell commands;
- install packages;
- use `sudo`;
- run build/test processes;
- use a private Docker Engine;
- access allowed public HTTP/HTTPS endpoints.

OpenCode approval prompts are disabled by design. A compromised agent or dependency should therefore be treated as having full control of the sandbox.

The security question is not whether hostile code can become powerful **inside** the microVM. The important question is what a fully compromised sandbox can reach **outside** it.

## Host-side controls

The hardened default profile uses:

- Docker Sandboxes clone mode;
- a private writable Git clone for agent work;
- a read-only host source view at the sandbox boundary;
- disabled shared host skills;
- disabled SSH agent forwarding;
- no host Docker socket;
- no intentionally published sandbox ports;
- public wildcard network access limited to TCP 80/443;
- explicit denies for common private/LAN/link-local ranges;
- explicit denies for host localhost ports 80/443;
- default deny for unmatched network destinations/ports;
- one intended host-service exception: the configured llama.cpp loopback port;
- llama.cpp bound to host `127.0.0.1`;
- effective-policy verification before OpenCode starts;
- passive Git handoff under `refs/ocbox/*`;
- host `HEAD` and working-tree integrity verification;
- microVM destruction only after verified preservation.

## Why not `allow **`?

Do not replace the hardened network policy with an unrestricted `allow **` rule.

During development, an executable isolation test demonstrated that a bare network wildcard also made arbitrary Windows localhost HTTP services reachable through the sandbox host gateway in the tested environment.

OCBox therefore permits broad public HTTP/HTTPS only on ports 80/443 and relies on default deny for other destinations/ports.

## Executable security checks

Run the complete local gate:

```powershell
.\sandbox.ps1 validate
```

Or run the host-isolation test directly:

```powershell
.\sandbox.ps1 security-test
```

The current test includes positive and negative controls for:

- public web access;
- private CIDR denial;
- localhost 80/443 denial;
- an unapproved random Windows localhost HTTP service;
- an explicitly approved localhost service;
- host source read-only behavior;
- private-clone isolation from the host working tree;
- a host file outside the workspace;
- SSH agent forwarding;
- availability of the sandbox's private Docker Engine;
- separation between the sandbox Docker Engine and the host Docker Engine.

Run the Git lifecycle check directly with:

```powershell
.\sandbox.ps1 handoff-test
```

It verifies that sandbox-only work can be snapshotted, exported through a verified Git bundle, imported into passive refs, survive sandbox destruction, and leave the host working tree unchanged.

## Source confidentiality is not guaranteed

**Full public Internet access and source-code confidentiality are incompatible if the sandbox itself is considered hostile.**

A malicious agent or dependency that can read source code and reach arbitrary public HTTPS endpoints can exfiltrate that source without escaping the microVM.

The default profile is primarily an isolation boundary for:

- the wider host filesystem;
- host credentials;
- local services;
- the host Docker daemon;
- the private/LAN network;
- the checked-out host repository.

OCBox is not a DLP system.

For confidential source where exfiltration is unacceptable, use a strict outbound allowlist or an architecture with dedicated outbound inspection/DLP.

## Untrusted output

Treat every OCBox result like an untrusted pull request.

Do not automatically execute, merge, or check out agent output on the host.

Review changes first, including files that can trigger code indirectly:

- CI workflows;
- Git hooks/config;
- editor tasks;
- package lifecycle scripts;
- build systems;
- installer configuration;
- container definitions;
- generated binaries.

Use:

```powershell
.\sandbox.ps1 review C:\path\to\project
```

before creating a local review branch.

## Residual risk

A successful `security-test` means the tested controls behaved as expected in that environment. It does **not** prove the absence of exploitable vulnerabilities.

Residual risk includes vulnerabilities in:

- Docker Sandboxes;
- the microVM/hypervisor stack;
- network proxy/policy enforcement;
- Windows;
- Git parsing and object import;
- other trusted host components.

OCBox should not be treated as a dedicated malware-analysis environment for intentionally detonating real malware on a personal workstation.

If that is your use case, add another isolation layer such as a disposable dedicated VM/host with no personal credentials or sensitive network access.

## Fail-safe preservation

If OCBox cannot prove that agent work has been safely preserved, the preferred failure mode is to **leave the sandbox alive** rather than destroy it and risk data loss.

Automatic destruction is deliberately blocked for repository states that need dedicated preservation logic, including Git LFS content, multiple worktrees, ignored files, and dirty/diverged submodules.

## Reporting a vulnerability

Please do not publish a working host escape, credential-exposure exploit, or similarly actionable vulnerability as a public issue before the maintainer has had a reasonable opportunity to investigate it.

If no private reporting channel is available, open a minimal issue requesting a private security contact without including exploit details.
