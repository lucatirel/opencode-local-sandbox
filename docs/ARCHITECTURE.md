# OCBox architecture

OCBox separates **agent capability** from **host trust**.

The agent is intentionally powerful inside a disposable Docker Sandbox microVM. The host-side wrapper controls what reaches the microVM, what can return from it, and when the environment may be destroyed.

## Runtime components

### Windows host

Trusted for the OCBox threat model:

- PowerShell wrapper code
- Git client used for host-side verification/import
- Docker Sandboxes runtime and its VM/network boundary
- local `llama-server.exe`
- the checked-out source repository

llama.cpp and model weights are external dependencies. OCBox does not vendor or manage them.

### Docker Sandbox microVM

Treated as potentially compromised:

- OpenCode
- shell tools
- package managers
- downloaded dependencies
- build/test processes
- private Docker Engine
- the agent-created working tree

The sandbox has a private Git clone. The source view supplied by Docker Sandboxes is expected to remain read-only.

## Session lifecycle

```text
host repo
   │
   ├─ Docker Sandboxes clone mode
   ▼
private clone in microVM
   │
   ├─ OpenCode works freely
   │
   ▼
Git snapshot commit
   │
   ▼
Git bundle created inside sandbox
   │
   ├─ copied to host
   ├─ bundle verified
   ▼
fetch into refs/ocbox/<session>/snapshot
   │
   ├─ verify host HEAD unchanged
   ├─ verify host working tree unchanged
   ▼
destroy microVM
```

The host working tree is never the automatic destination of agent output.

## Network boundary

The default profile gives the sandbox useful web access while trying to exclude the host and private network:

- public wildcard allow: `**:80,**:443`
- explicit private/LAN/link-local denies
- explicit `localhost:80` and `localhost:443` denies
- default deny for unmatched destinations/ports
- explicit allow for `localhost:<configured llama port>`

OCBox checks policy decisions after installing rules. It does not assume that a successful policy-write command means the effective policy matches the threat model.

## Why passive Git refs?

Checking out agent output would immediately move untrusted content into a normal developer workflow where editor hooks, build scripts, package lifecycle scripts, CI configuration, and other indirect execution paths may trigger.

Passive `refs/ocbox/*` make the handoff observable without automatically executing or merging anything.

## Fail-safe destruction

The microVM is disposable only after preservation is proven.

Automatic destruction is refused when OCBox cannot safely preserve repository state, including currently guarded cases such as:

- ignored files that would not be represented by the Git snapshot;
- multiple Git worktrees;
- Git LFS tracked content without dedicated LFS transport;
- dirty or diverged submodules;
- bundle creation/copy/verification/import failure;
- host working-tree integrity failure.

This is intentionally conservative: leaking a sandbox is preferable to silently losing agent work.

## Non-goals

OCBox is not intended to provide:

- malware-analysis-grade containment;
- protection against unknown hypervisor/sandbox escapes;
- source-code DLP with unrestricted HTTPS egress;
- model management or llama.cpp build automation;
- automatic trust of agent-produced code.
