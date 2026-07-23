---
type: master-spec
repo: revcon
last-updated: 2026-07-23
owner: RevealUI Studio
staleness-status: FRESH
---

# RevCon — Master Spec

**Last Updated:** 2026-07-23
**Status:** Pre-1.0 — surface stable for studio internal use; two profiles shipped (`revealui`, `revfleet`)
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
│   ├── revealui/
│   │   ├── agents/        # Claude Code agent definitions
│   │   ├── claude/        # Claude rules + skills
│   │   ├── cursor/        # cursor rules
│   │   └── zed/           # zed-specific overrides
│   └── revfleet/
│       └── claude/rules/  # shared fleet-wide rules
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
| `--profile <name>` | (none — base only) | Profile to overlay on base; repeatable. `profiles/` ships `revealui` and `revfleet` today; later `--profile` wins on filename collision |
| `--editor <name>` | (all) | Limit to one editor: `cursor`, `zed`, `vscode`, `claude`, `agents` |
| `--skip <name>` | (none) | Skip an editor (repeatable; also settable via `REVCON_SKIP_EDITORS`) |
| `--dry-run` | off | Preview without writing |
| `--list` | (mode) | Enumerate available profiles, exit |
| `-h`, `--help` | (mode) | Show usage, exit |

Behavior:

1. Validates `--target` exists and is a directory
2. Computes the symlink set: `base/<editor>/*` + (if profile) `profiles/<profile>/*`. It does NOT link `harnesses/*` — harness content ships via the `revealui-harnesses` CLI, not `link.sh`.
3. For each source file, creates a symlink at the corresponding target path
4. **Existing symlink → a revcon source**: re-linked. **Existing symlink → a different source**: replaced with an `[update]` message (the `--force` guard for foreign symlinks is the open Phase 1 item)
5. **Existing real files**: SKIPPED with a `[skip] … real file exists` message — never overwritten. Back up or remove the file to link over it
6. Reports created/skipped counts

### `unlink.sh`

| Flag | Purpose |
|---|---|
| `--target <path>` | Target project directory |
| `--editor <name>` | Limit to one editor: `cursor`, `zed`, `vscode`, `claude`, `agents` |
| `--skip <name>` | Skip an editor (repeatable; also settable via `REVCON_SKIP_EDITORS`) |
| `--dry-run` | Preview without removing |
| `-h`, `--help` | Show usage, exit |

Removes only files that are symlinks pointing into the revcon repo (or into `REVCON_PRIVATE_PROFILES_DIR` when set). Real files at target paths are left untouched.

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
~/revfleet/revealui/.claude/agents/...  → revcon/profiles/revealui/claude/agents/...
~/revfleet/revealui/.claude/rules/...   → revcon/profiles/revealui/claude/rules/...
~/revfleet/revealui/.claude/skills/...  → revcon/profiles/revealui/claude/skills/...
```

This is produced by `--editor claude` (mapped to `.claude/` via `link.sh`'s
`EDITOR_DIRS`). `--editor agents` symlinks `.agents/` from
`profiles/<profile>/agents/` the same way. Neither editor touches
`harnesses/*`; see "Behavior" above.

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
| Target has existing symlink → other source | Replaced (`[update]` message) | Refuse without `--force`; warn |
| Target has existing real file | Skipped (`[skip]` message) — never overwritten | (no change — already safe) |
| Target file does not exist | Create symlink | OK (no change) |

Real files are already safe (skipped). The open Phase 1 gap is the foreign-*symlink* case: `link.sh` currently replaces a symlink pointing at a non-revcon source; Phase 1 in `MASTER_PLAN.md` adds a `--force` guard for that.

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
