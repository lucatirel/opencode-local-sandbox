# Repository purpose

This repository is tooling for running OpenCode with a local llama.cpp model inside disposable Docker Sandbox microVMs. It is not itself the default target project.

The central design principle is: **the agent and everything it downloads may be hostile; the Windows host is the trust boundary.**

## Rules for contributors

- Keep machine-specific paths, models, credentials, private keys and generated state out of Git.
- Preserve Windows PowerShell compatibility unless the minimum version is intentionally changed and documented.
- Never replace the hardened network policy with a bare `allow **` rule.
- Scope Docker Sandbox network rules to the specific sandbox with `--sandbox`.
- Preserve clone mode: the agent must work in its private in-VM Git clone, not a writable host working tree.
- Keep shared host skills and SSH-agent forwarding disabled in the hardened default profile.
- Do not expose the host Docker socket or silently publish sandbox ports.
- The llama.cpp host process must bind to loopback; host access from the sandbox must remain an explicit port exception.
- Do not make ports 80 or 443 valid llama host exceptions while localhost 80/443 are explicit deny rules.
- Agent output must land in passive `refs/ocbox/*` refs. Do not auto-checkout, auto-merge or execute it on the host.
- Sandbox destruction must happen only after verified Git preservation. On any preservation failure, keep the sandbox alive.
- Preserve the ignored-file guard: do not destroy a sandbox if Git would omit potentially valuable ignored output.
- `security-test` must retain meaningful negative and positive controls for the host-service boundary.
- `handoff-test` must exercise an actual OpenCode-agent sandbox, not a weaker shell-only substitute.
- Keep `sandbox.ps1` small and obvious; implementation details belong under `scripts/`.
- Validate all PowerShell files with the parser and run dependency-free static tests before merging.
- Treat changes to `.github`, build scripts, package scripts, editor automation and other indirect execution paths as security-sensitive.
- Never claim absolute isolation. Document residual Docker Sandboxes/microVM/proxy/host risk explicitly.

## Public-facing security claim

The project may describe itself as strong practical isolation / defense in depth for a hostile local coding agent. It must not claim that host escape is impossible or that unrestricted public web access protects source confidentiality.
