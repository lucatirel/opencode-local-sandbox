# Contributing to OCBox

OCBox is security-sensitive infrastructure. Small changes to networking, filesystem exposure, process launching, Git handoff, or cleanup behavior can materially change the trust boundary.

## Development setup

Use Windows with the same prerequisites described in [README.md](README.md):

- PowerShell 5.1 or 7
- Git
- Docker Sandboxes CLI (`sbx`)
- an external working llama.cpp installation and GGUF model for real OpenCode sessions

The dependency-free tests do not require llama.cpp.

## Before changing code

Read:

- [README.md](README.md)
- [SECURITY.md](SECURITY.md)

In particular, preserve these invariants unless the change intentionally redesigns the security model:

1. the agent works in a private clone, not the writable host working tree;
2. the host Docker socket is not exposed;
3. SSH agent forwarding remains disabled;
4. public wildcard network access is restricted to 80/443;
5. private/LAN/link-local networks remain denied by default;
6. only the configured llama.cpp host endpoint is explicitly allowed;
7. agent output returns as passive Git refs;
8. host `HEAD` and working-tree status remain unchanged during handoff;
9. a sandbox is destroyed only after its output is verified on the host;
10. preservation uncertainty fails safe and leaves the sandbox intact.

## Validation

Run the complete local gate:

```powershell
.\sandbox.ps1 validate
```

It must end with:

```text
OCBOX VALIDATION: PASS
```

For fast dependency-free checks only:

```powershell
.\tests\static-tests.ps1
```

GitHub-hosted CI runs syntax/JSON/static checks. The Docker Sandbox integration checks run locally because they require a real `sbx` environment.

## Pull requests

Keep changes focused and explain:

- what behavior changed;
- whether the trust boundary changed;
- which validation commands were run;
- any new residual risk;
- whether failure behavior remains fail-safe.

Do not bundle unrelated formatting refactors into security-sensitive changes.

## Security findings

Do not publish a working host escape, credential exposure, or similar exploit in a public issue before the maintainer has had a reasonable opportunity to investigate it.

Follow the reporting guidance in [SECURITY.md](SECURITY.md).
