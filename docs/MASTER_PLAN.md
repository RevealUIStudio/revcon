---
type: master-plan
repo: revcon
last-updated: 2026-05-10
owner: RevealUI Studio
staleness-status: FRESH
---

# RevCon — Master Plan

**Last Updated:** 2026-05-10
**Status:** Active — symlink-based config sync; one profile shipped (`revealui`)
**Owner:** RevealUI Studio (`founder@revealui.com`)
**Repo:** [RevealUIStudio/revcon](https://github.com/RevealUIStudio/revcon)
**Fleet master index:** RevealUI Studio internal coordination hub (`MASTER_INDEX.md`, private).

> Fleet-level cross-cutting plans live in the internal coordination hub's `MASTER_PLAN.md`. This file is RevCon-scoped only.

---

## Current Reality (2026-05-10)

### What exists

- **`link.sh`** — symlinks editor configs + agent rules into a target project (`--target <path> --profile <name>`)
- **`unlink.sh`** — removes the symlinks (idempotent)
- **`status.sh`** — reports on existing symlinks per target
- **`base/`** — universal configs sourced into every target (Cursor + Zed)
- **`profiles/revealui/`** — RevealUI-specific overlay (Cursor + Zed + Claude rules + agents)
- **`harnesses/`** — agents + commands + generators + manifest + rules + skills (Claude Code-shaped harness shipped to targets)
- **List mode**: `link.sh --list` enumerates available profiles
- **Single-editor mode**: `link.sh --editor zed` only links one editor's configs
- **Dry-run mode**: `link.sh --dry-run` previews without changes

### What works

| Capability | Status | Confidence |
|---|---|---|
| `link.sh --target X --profile revealui` | Built | High — Joshua's standing pattern across all RevealUI fleet repos |
| `link.sh --target X` (base only, no profile) | Built | High |
| `unlink.sh --target X` | Built | High — clean removal of all symlinks |
| Per-editor link (`--editor zed/cursor`) | Built | High |
| Dry-run preview | Built | High |
| Profile listing | Built | High |

### What does not exist yet

- Profiles other than `revealui` — only one shipped today; future profiles for non-RevFleet projects when needed
- Conflict detection — `link.sh` overwrites existing symlinks silently; no "this looks unrelated, are you sure" guard
- Sync direction (target → revcon) — currently one-way; if a contributor edits config inside a linked project, the change isn't propagated back automatically
- Test coverage — `link.sh` has no automated test harness; smoke-tested manually

---

## Composition with the rest of RevFleet

RevCon is **not Pro-gated** — any contributor can run `link.sh` and get the team's editing posture, agent rules, and convention files. There is no `@revealui/editors` package in the RevealUI monorepo; RevCon is the canonical product for this surface.

| Other product | Relationship |
|---|---|
| **RevealUI** | Symlinks `.cursor/`, `.zed/`, `.claude/` into the RevealUI monorepo |
| **RevDev** | Studio integrates with RevCon for editor configs |
| **RevKit** | RevKit provisions portable Zed config; RevCon overlays project-specific configs (no overlap) |
| **RevVault, RevForge, RevSkills** | Independent — RevCon doesn't touch their internals |

---

## Active Work

### Current branch: `main` (clean)

No active feature work. Recent stability — RevCon has been stable since the harness extraction.

---

## Roadmap

Pre-1.0 per the fleet versioning convention (RevealUI Studio internal). Promotion gated on a second profile being added (proves the abstraction is real, not just RevealUI-specific).

### Phase 0 — Symlink-based sync for RevealUI (DONE)

`link.sh`/`unlink.sh`/`status.sh` shipped. RevealUI profile carries the studio's editing + agent posture. Pattern proven across multiple linked targets.

### Phase 1 — Test coverage + conflict detection (NOT STARTED)

| Sub-phase | Owner |
|---|---|
| Smoke-test harness exercising link → status → unlink → status round-trip | Agent |
| Conflict detection — refuse to overwrite a non-symlinked file in target without `--force` | Agent |
| ShellCheck CI gate | Agent |

### Phase 2 — Second profile (NOT STARTED)

Add a second profile (e.g. `agency` or `personal`) with different editor + agent rules. Validates the profile abstraction.

### Phase 3 — Bidirectional sync (DEFERRED)

If a contributor edits agent rules inside a linked target, surface the diff back to RevCon. Currently manual: contributor edits in revcon repo, then re-runs `link.sh` (symlinks don't actually need re-running since they point at the source — edits propagate live). The "bidirectional" concern is when a contributor edits in the *target* not realizing they're editing the source — clearer warnings + status output cover this without true bidirectional sync.

---

## Owner Action Queue

| # | Item | Unblocks | Priority |
|---|---|---|---|
| 1 | Decide whether RevCon should be public on GitHub or stay studio-internal | Phase 2 (when adding non-RevealUI profiles) | Medium |
| 2 | If public: license decision (MIT default) | Phase 2 | Medium |

---

## See also

- [`docs/MASTER_SPEC.md`](./MASTER_SPEC.md) — surface area + symlink contract
- [`README.md`](../README.md) — quick start + usage patterns
- Fleet master index (`MASTER_INDEX.md` in the RevealUI Studio internal coordination hub) — fleet-level navigation
