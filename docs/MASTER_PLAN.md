---
type: master-plan
repo: revcon
last-updated: 2026-07-23
owner: RevealUI Studio
staleness-status: FRESH
---

# RevCon — Master Plan

**Last Updated:** 2026-07-23  
**Status:** Active — symlink + **copy-mode** materialization; profiles **`revfleet`** + **`revealui`**  
**Owner:** RevealUI Studio  
**Repo:** [RevealUIStudio/revcon](https://github.com/RevealUIStudio/revcon)

> Fleet-level plans live in the private coordination hub. This file is RevCon-scoped only.  
> **Code-over-docs:** `link.sh --list` and `profiles/` win over prose.

---

## Current reality (2026-07-23)

### What exists

- **`link.sh` / `unlink.sh` / `status.sh`** — link, remove, and verify editor configs + agent rules  
- **`base/`** — universal Cursor + Zed (and related) configs  
- **`profiles/revfleet`**, **`profiles/revealui`** — layered overlays (`--profile` is repeatable; later wins)  
- **Copy mode** — `--mode copy` materializes tracked files + `.revcon-manifest.json` (sha256); used for monorepo rules-lockstep  
- **`harnesses/`** — agents, commands, generators, rules, skills (Claude Code-shaped material shipped into targets)  
- **Dry-run / list / single-editor** flags as documented in `README.md`

### What works

| Capability | Status | Confidence |
|---|---|---|
| Symlink link/unlink | Built | High — fleet daily driver |
| Multi-profile overlay | Built | High — revfleet + revealui |
| Copy-mode materialize + manifest | Built | High — revealui `validate:rules-lockstep` consumers |
| Harness generators under `harnesses/` | Built | High |

### Residuals

| Item | Notes |
|---|---|
| Additional non-fleet profiles | Only fleet profiles shipped today |
| Bidirectional sync (target → revcon) | One-way; edit profiles, re-link |
| Automated test harness for `link.sh` | Smoke-tested; expand when needed |

---

## Composition

RevCon is not Pro-gated. It is the canonical editor/agent config product for RevFleet (no parallel `@revealui/editors` package).

| Other product | Relationship |
|---|---|
| **RevealUI** | Primary consumer of copy-mode Claude rules + agents |
| **RevKit** | Host/bootstrap; RevCon overlays project configs |
| **Others** | Independent |

---

## Roadmap

| Phase | Intent | State |
|---|---|---|
| 0 Symlink revealui profile | Done | |
| 1 Multi-profile + harness pack | Done | |
| 2 Copy-mode + lockstep consumers | Done (in use) | |
| 3 Extra profiles / test harness | Deferred | |

---

## See also

- [`../README.md`](../README.md)  
- [`docs/MASTER_SPEC.md`](./MASTER_SPEC.md)  
