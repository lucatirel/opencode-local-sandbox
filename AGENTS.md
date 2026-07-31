# Repository purpose

This repository is tooling for launching OpenCode in one Docker Sandbox per target project. It is not itself the default target project.

## Rules for contributors

- Keep machine-specific paths, models, private keys and generated state out of Git.
- Preserve Windows PowerShell 5.1 compatibility unless the minimum version is intentionally changed and documented.
- Scope Docker Sandbox network rules with `--sandbox`; do not add global allow rules.
- A target project must be the primary and only writable host workspace mounted into its sandbox.
- Verify an existing sandbox's agent and workspace before reusing, stopping or removing it.
- Keep shared agent skills disabled by default; enabling a cross-sandbox writable store must be an explicit local choice.
- Do not copy the template repository into target projects.
- Keep `sandbox.ps1` commands simple; advanced options belong in scripts under `scripts/`.
- Validate all PowerShell files with the parser and validate JSON before merging.
- Destructive sandbox removal must remain explicit and must never delete the host project directory.
- Reconcile only network rules recorded as tool-managed; preserve unrelated user rules.
