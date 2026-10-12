# Preservation hardening — first patch

This patch addresses accidental sandbox adoption and deletion, and known gaps in
the Git preservation guard. It does not complete the security review or establish
that the current build is ready for unattended work on Draco.

## Code boundaries

| Component | Responsibility |
| --- | --- |
| `scripts/private/SandboxIdentity.ps1` | Hardened flags, host ownership receipts, runtime ID/agent/workspace checks |
| `scripts/private/preservation-guard.sh` | In-VM repository states that block snapshot/removal |
| `scripts/private/GitHandoff.ps1` | Snapshot, verified bundle import, passive refs and removal checks |
| `scripts/cleanup.ps1` | Preview or explicit removal of a registered test sandbox |
| `tests/security-regressions.ps1` | Mocked lifecycle failures and positive controls |
| `tests/preservation-tests.py` | Production guard with real disposable Git repositories |

The launcher remains small. The shell guard is a standalone resource so tests
execute the same commands used in the VM, without extracting PowerShell strings.

## Behavioral changes

- `open` and `handoff` reject disabled clone/shared-skill/SSH protections.
- A successful clone/no-shared-skills creation is recorded on the host. Subsequent
  use checks runtime ID, agent and exactly one matching host workspace. A reused
  name alone is insufficient. An explicit non-clone runtime value is rejected.
- Legacy sandboxes and stale receipts are not automatically adopted or replaced.
- Cleanup never selects candidates by name prefix. No target means preview only;
  explicit cleanup requires a matching test receipt and uses ordinary `sbx rm`.
  A cancelled or failed removal retains the receipt.
- The repository guard rejects clean submodules as well as dirty ones, detects
  LFS attributes and current pointer files without git-lfs, and checks the exit
  status of LFS enumeration when the client exists. Git inspection failures abort.
- The passive ref SHA is verified before removal. Handoff failures retain the VM;
  the integration test now also keeps its host repository on failure.
- Manual handoff suppresses the caller's `SSH_AUTH_SOCK` and restores it afterward.
  This is not a claim that daemon-configured forwarding or secrets are disabled.

## Compatibility and migration

The identity adapter requires machine-readable `sbx ls --json` with `name`, `id`,
`agent`, and `workspaces` (one absolute path string). It accepts a `sandboxes`
wrapper or a top-level array; it does not guess missing fields or parse table text.
Unknown schemas and nonzero commands stop the workflow without deleting the VM.
The CLI flag is [documented by Docker](https://docs.docker.com/reference/cli/sbx/ls/),
but this patch has not captured a live Windows response. That remains an integration gate.

Receipts live in ignored `.local/sandboxes/` within the OCBox checkout, outside the
target project. They must not be moved into the agent workspace or committed.
They are host bookkeeping, not cryptographic attestation against a compromised host.
Run OCBox from a tooling checkout separate from the target project: exposing the
tooling checkout also exposes its local state to that sandbox's read-only view.

Do not delete a legacy sandbox to unblock the wrapper. Inspect and export its work
manually first. There is intentionally no automatic receipt adoption. In this
patch, `handoff-test` registers its disposable sandbox; other legacy test scripts
are not eligible for the new cleanup command merely because their names look like tests.

## Validation and next gates

Local Linux checks: PowerShell parser, PowerShell 7 static/mocked regressions, and
real-Git guard tests. The suite includes positive controls, same-name replacement,
wrong/extra workspace, invalid metadata, cancelled cleanup, missing/changed passive
ref, clean submodule with local-only output, LFS without its client, and inspection
failure. No real microVM was started or destroyed during these checks.

Before merging/releasing, run the Windows 5.1/7 CI and on Draco:

```powershell
.\sandbox.ps1 handoff-test
.\sandbox.ps1 validate
.\sandbox.ps1 adversarial-test
```

Use disposable test data and retain any failed sandbox. Confirm the actual JSON
adapter and host receipt against the installed sbx version before opening projects.

## Remaining development order

1. Reconcile network rules by exact desired state: switching off public web or
   changing the llama port must remove stale grants. Treat policy-check errors as errors.
2. Isolate project ingress: a read-only host source view can still disclose ignored
   secrets. Verify daemon-managed credentials, forwarding, MCP and published ports.
3. Make preservation quiescent and recoverable: prevent concurrent writers,
   strengthen host integrity checks, cover non-branch refs and unsupported data,
   retain a durable handoff manifest, and avoid forced removal of active sessions.
   Current LFS detection is conservative but is not exhaustive historical object
   analysis when git-lfs is absent. Files outside the clone are not preserved.
4. Separate an externally managed llama.cpp router from OCBox process ownership;
   replace the TCP-only readiness probe with API/model checks for the large Qwen models.

These are open items, not guarantees supplied by this patch. Keep future modules
focused on lifecycle, network, backend and handoff boundaries; avoid a broad
directory reorganization before the behavioral regression suite covers them.
