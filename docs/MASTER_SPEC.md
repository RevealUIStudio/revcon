---
type: master-spec
repo: revcon
last-updated: 2026-05-10
owner: RevealUI Studio
staleness-status: FRESH
---

# RevCon — Master Spec

**Last Updated:** 2026-05-10
**Status:** Pre-1.0 — surface stable for studio internal use; one profile (`revealui`)
**Repo:** [RevealUIStudio/revcon](https://github.com/RevealUIStudio/revcon)

> Surface area + symlink contract. Companion to [`MASTER_PLAN.md`](./MASTER_PLAN.md) (status + roadmap).

---

## Mission

Centralized editor configs + agent harnesses for RevealUI Studio projects. Configs live in this repo; targets receive them via symlinks. Edits in this repo propagate **instantly** to every linked target — no copy step, no commit step, no per-project drift.

---

## Repository structure

```
revcon/
├── README.md
├── link.sh                # link configs into a target (--target X --profile Y)
├── unlink.sh              # remove the symlinks
├── status.sh              # report on existing symlinks
├── base/                  # universal configs (linked into every target)
│   ├── cursor/
│   │   ├── .cursorignore
│   │   ├── environment.json
│   │   └── snippets/
│   └── zed/
│       └── settings.json
├── profiles/              # per-project overlays (layered on base)
│   └── revealui/
│       ├── agents/        # Claude Code agent definitions
│       ├── claude/        # Claude rules + skills
│       ├── cursor/        # cursor rules
│       └── zed/           # zed-specific overrides
└── harnesses/             # full Claude Code harness shipped to targets
    ├── agents/
    ├── commands/
    ├── generators/
    ├── manifest.json
    ├── rules/
    └── skills/
```

---

## CLI surface

### `link.sh`

| Flag | Default | Purpose |
|---|---|---|
| `--target <path>` | (required) | Target project directory (where symlinks land) |
| `--profile <name>` | (none — base only) | Profile to overlay on base; `revealui` is the only profile shipped today |
| `--editor <zed\|cursor>` | (all) | Limit to a single editor's configs |
| `--dry-run` | off | Preview without writing |
| `--list` | (mode) | Enumerate available profiles, exit |

Behavior:

1. Validates `--target` exists and is a directory
2. Computes the symlink set: `base/*` + (if profile) `profiles/<profile>/*` + (always) `harnesses/*`
3. For each source file, creates a symlink at the corresponding target path
4. **Existing symlinks**: silently overwritten (treated as a re-link)
5. **Existing real files**: currently overwritten silently (Phase 1 fix planned: refuse without `--force`)
6. Reports created/skipped counts

### `unlink.sh`

| Flag | Purpose |
|---|---|
| `--target <path>` | Target project directory |
| `--dry-run` | Preview without removing |

Removes only files that are symlinks pointing into the revcon repo. Real files at target paths are left untouched.

### `status.sh`

Reports per-target:
- Symlinks present and pointing into revcon (✓)
- Symlinks present but pointing elsewhere (⚠ — likely user-modified)
- Real files present at expected symlink paths (⚠ — link would conflict)

---

## Symlink layout

For target `~/revfleet/revealui` with `--profile revealui`:

```
~/revfleet/revealui/.cursorignore       → revcon/base/cursor/.cursorignore
~/revfleet/revealui/.cursor/rules/...   → revcon/profiles/revealui/cursor/rules/...
~/revfleet/revealui/.zed/settings.json  → revcon/base/zed/settings.json
~/revfleet/revealui/.zed/...override... → revcon/profiles/revealui/zed/...
~/revfleet/revealui/.claude/rules/...   → revcon/profiles/revealui/claude/rules/...
~/revfleet/revealui/.claude/agents/...  → revcon/profiles/revealui/agents/...
~/revfleet/revealui/.claude/commands/...→ revcon/harnesses/commands/...
~/revfleet/revealui/.claude/skills/...  → revcon/harnesses/skills/...
~/revfleet/revealui/.claude/manifest.json → revcon/harnesses/manifest.json
```

Profile overrides win over base (when both define the same target path).

---

## Profile schema

A profile is a directory under `profiles/<name>/`. Convention:

- `cursor/` — Cursor-specific overlay
- `zed/` — Zed-specific overlay
- `claude/` — Claude Code rules + skills
- `agents/` — agent definitions

Adding a new profile = create the directory + populate it. No manifest file required (intentionally low-ceremony).

---

## Conflict resolution

| Situation | Current behavior | Phase 1 target |
|---|---|---|
| Target has existing symlink → revcon source | Silently re-link | OK (no change) |
| Target has existing symlink → other source | Silently overwrite | Refuse without `--force`; warn |
| Target has existing real file | Silently overwrite | Refuse without `--force`; warn |
| Target file does not exist | Create symlink | OK (no change) |

The current "silently overwrite" pattern is a known gap; Phase 1 in `MASTER_PLAN.md` adds the `--force` guard.

---

## Pro-gating

**RevCon is NOT gated by the RevealUI Pro license.** Anyone can run `link.sh`. This is intentional — editor configs + agent rules are productivity infrastructure, not commercial features.

The previous `@revealui/editors` package (in the RevealUI monorepo) was retired in favor of RevCon as the canonical surface for this concern.

---

## Versioning

Pre-1.0 per the fleet versioning convention (RevealUI Studio internal). No `package.json` — repo is shell scripts + config files. Version signal is git tag (none yet) + commits.

---

## Compose / coexistence

| Other product | Relationship |
|---|---|
| **RevealUI** | Primary consumer — `revealui` profile carries the monorepo's editor + agent posture |
| **RevDev** | Studio integrates RevCon for editor configs |
| **RevKit** | Pairs cleanly — RevKit installs portable Zed config; RevCon overlays project-specific configs |
| **RevVault, RevForge, RevSkills, .jv** | Independent |

---

## See also

- [`docs/MASTER_PLAN.md`](./MASTER_PLAN.md) — current status, phases, owner actions
- [`README.md`](../README.md) — quick start
- Fleet master index (`MASTER_INDEX.md` in the RevealUI Studio internal coordination hub) — fleet-level navigation
