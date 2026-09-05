# OCBox roadmap

OCBox is intentionally narrow: **OpenCode + local llama.cpp + Windows + Docker Sandboxes**.

The roadmap prioritizes a boring, testable host boundary before adding breadth.

## v0.1 — public release

- [x] private clone instead of writable host worktree
- [x] passive `refs/ocbox/*` Git handoff
- [x] verified Git bundle import
- [x] fail-safe preservation before sandbox destruction
- [x] private/LAN/link-local network denies
- [x] explicit llama.cpp host exception
- [x] no host Docker socket
- [x] no SSH-agent forwarding
- [x] host-isolation regression suite
- [x] controlled adversarial containment suite
- [x] Git-history pre-publication audit
- [x] add a short real-world demo GIF/video
- [ ] publish first tagged release

## v0.2 — harder containment testing

- [ ] nested privileged-container abuse tests
- [ ] broader Docker socket and mount discovery probes
- [ ] symlink/path-traversal regression tests
- [ ] alternate network-addressing / DNS bypass probes
- [ ] host gateway and random-port probes
- [ ] persistence tests across sandbox destruction
- [ ] hostile Git refs/object naming tests
- [ ] interrupted handoff recovery tests

## v0.3 — Git edge cases

- [ ] dedicated Git LFS preservation path
- [ ] multiple worktree support
- [ ] ignored-file preservation policy
- [ ] more complete submodule handoff support
- [ ] richer snapshot review UX

## Later / only if it stays simple

- [ ] additional local OpenAI-compatible backends
- [ ] more Windows hardware presets
- [ ] optional strict-egress profile for confidential repositories
- [ ] reusable CI recipe for projects developed through OCBox

## Non-goals

Unless the architecture changes substantially, OCBox is not trying to become:

- a malware-analysis environment;
- a DLP product;
- a generic cloud agent platform;
- a replacement for Docker Sandboxes;
- a universal cross-platform local-LLM manager.

If you want to propose an item, open an issue and describe the user problem first. Security-relevant changes should include a regression-test idea whenever practical.
