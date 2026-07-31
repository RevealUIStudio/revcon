---
title: GAP-372 — shared copy-mode lockstep gate
date: 2026-07-31
status: decided
---

# GAP-372 design: one shared gate, not six ports

## Decision

**Shared gate (option b).** Do not port `revealui/scripts/validate/rules-lockstep.ts`
into each fleet repo. Author one gate in revcon and call it from every consumer.

| Piece | Role |
|-------|------|
| `scripts/verify-copy-lockstep.sh` | **CI SSOT** — self-consistency only (manifest hashes + no git strays). No profile checkout required. |
| `status.sh --verify` | **Operator** — same drift report plus profile-source staleness when this revcon tree is present. Exit 1 on drift. |
| `revealui` `pnpm validate:rules-lockstep` | Existing monorepo TS gate; remains the revealui-native path. Shared shell gate is the fleet default for non-TS repos. |

## Why not per-repo TS ports

- Six copies of the same checker will drift (fleet-redundancy / extend-before-create).
- Most fleet repos are not a revealui-style TS monorepo with a `validate:` script surface.
- CI for a consumer only needs the **tracked tree** to match its **own** manifest; comparing to live profiles is an operator/bootstrap concern.

## Rollout shape (per consumer)

1. `.gitignore`: use `.claude/*` + negations for `rules/`, `agents/`, `skills/`, `.revcon-manifest.json` (not bare `.claude/`).
2. `link.sh --target <repo> --profile revfleet --editor claude --mode copy` (add profiles as needed).
3. `git add` the materialized paths + manifest.
4. CI step: `bash path/to/verify-copy-lockstep.sh --target .` (checkout this repo or copy the script; SSOT is here).
5. revkit `FLEET_TARGETS` entry uses `:copy`.

## Pilot order

`revdev` first (next after revealui in FLEET_TARGETS). Then revvault, revcon, revforge, revskills, revkit.
