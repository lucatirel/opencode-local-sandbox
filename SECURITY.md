# Security model

OCBox is designed around one assumption: **the coding agent and everything it downloads may be hostile**.

The goal is not to make OpenCode less capable. The goal is to give it broad freedom inside a disposable Docker Sandbox microVM while minimizing what that environment can reach on the Windows host.

## Trust boundaries

The agent is intentionally trusted with the sandbox and **not** trusted with the host.

Inside the microVM it may edit files, run shell commands, install packages, use sudo, run a private Docker Engine, and access public HTTP/HTTPS endpoints. OpenCode approval prompts are disabled by default.

The host-side controls are the important boundary:

- target repositories are opened with Docker Sandboxes clone mode;
- the host repository is not the agent's writable working copy;
- shared host skills are disabled;
- SSH agent forwarding is disabled;
- private/LAN/link-local address ranges are explicitly denied;
- public web wildcard access is limited to ports 80 and 443;
- host localhost ports 80 and 443 are explicitly denied;
- the only intended host service exception is the configured llama.cpp loopback port;
- the local llama.cpp server binds only to `127.0.0.1`;
- no host Docker socket is exposed to the sandbox;
- no sandbox ports are intentionally published;
- successful sessions are exported as passive Git objects under `refs/ocbox/*`, not checked out or merged automatically;
- the microVM is destroyed only after the Git handoff has been verified on the host.

## Why not `allow **`?

Do not replace the network policy with an unrestricted `allow **` rule.

During development, an executable isolation test demonstrated that such a rule also made arbitrary Windows localhost HTTP services reachable through `host.docker.internal`. The hardened profile therefore permits broad public HTTP/HTTPS only on ports 80/443 and relies on default deny for other outbound ports.

## Executable security checks

Run:

```powershell
.\sandbox.ps1 security-test
```

The test creates a disposable sandbox and checks, among other things:

- public web access works;
- private CIDRs are denied;
- localhost 80/443 are denied;
- an unapproved random Windows localhost HTTP service is unreachable;
- an explicitly approved localhost service is reachable, proving the negative control is meaningful;
- the host repository is read-only from the sandbox boundary;
- the private clone is isolated from the host working tree;
- a host file outside the workspace is inaccessible;
- `SSH_AUTH_SOCK` is not forwarded;
- the sandbox has its own Docker Engine and cannot use the host Docker daemon.

Run:

```powershell
.\sandbox.ps1 handoff-test
```

This verifies that work produced in an OpenCode clone can be snapshotted, exported via a Git bundle, imported into passive `refs/ocbox/*` refs, survive sandbox destruction, and leave the host working tree unchanged.

## Important limitation: source confidentiality

**Full Internet access and source-code confidentiality are incompatible if the sandbox itself is considered hostile.**

An agent or malicious dependency that can read source code and access arbitrary public HTTP/HTTPS endpoints can exfiltrate that source. This project is primarily an isolation boundary for the host system, credentials, LAN and local services; it is not a DLP system.

For confidential source where exfiltration is unacceptable, use a stricter egress allowlist or an architecture with dedicated outbound inspection/DLP.

## Untrusted output

Treat every OCBox result like an untrusted pull request.

Do not automatically execute, merge or checkout agent output on the host. Review changes first, including files that can trigger code indirectly such as CI workflows, Git hooks/config, editor tasks, package scripts, build systems and installer configuration.

Use:

```powershell
.\sandbox.ps1 review C:\path\to\project
```

before creating a local review branch.

## Residual risk

This is defense in depth, not a claim of perfect isolation. Residual risk includes vulnerabilities in Docker Sandboxes, its microVM/hypervisor stack, proxy/policy implementation, Windows, Git parsing, or other trusted host components.

## Reporting a vulnerability

Please do not publish a working host-escape or credential-exposure exploit as a public issue before the maintainer has had a reasonable opportunity to investigate it. Open a minimal issue requesting a private security contact if no private reporting channel is available on the repository.
