# Single Source of Truth — Agent Coordination Hub

## The Hub

All agent coordination, planning, and status tracking flows through ONE location:

```
~/suite/.jv/.claude/workboard.md   — agent coordination
~/suite/.jv/docs/MASTER_PLAN.md    — planning & task tracking
```

**There are no exceptions.** Every agent, subagent, worktree agent, and background task
reads from and writes to this hub — regardless of which repo they were launched from.

## What Lives Where

| Artifact | Canonical Location | Other copies |
|----------|-------------------|--------------|
| Workboard (agent sessions, tasks, files) | `~/suite/.jv/.claude/workboard.md` | `~/suite/revealui/.claude/workboard.md` = REDIRECT STUB ONLY |
| Master Plan (phases, tasks, status) | `~/suite/.jv/docs/MASTER_PLAN.md` | `~/suite/revealui/docs/MASTER_PLAN.md` = PUBLIC SNAPSHOT (stale OK) |
| Memory (persistent cross-session) | `~/.claude/projects/-home-joshua-v-dev-suite/memory/` | Project-scoped, do not duplicate |
| Plans (ephemeral session) | In-conversation only (EnterPlanMode) | NEVER write to `~/.claude/plans/` — they rot |

## Prohibited Actions

1. **Do NOT write agent sessions or tasks to `~/suite/revealui/.claude/workboard.md`** — it is a redirect stub
2. **Do NOT update `~/suite/revealui/docs/MASTER_PLAN.md` directly** — update the private version, sync later
3. **Do NOT create files in `~/.claude/plans/`** — use in-conversation plans or MASTER_PLAN
4. **Do NOT create planning/status files** (ACTION_PLAN.md, STATUS.md, TODO.md) anywhere — MASTER_PLAN is the only planning document
5. **Do NOT write memory to the wrong project context** — use the suite memory directory

## On Session Start

1. Read `~/suite/.jv/.claude/workboard.md` — check other agents' activity
2. Read `~/suite/.jv/docs/MASTER_PLAN.md` — verify task alignment
3. Update your workboard row with current task

## On Session End

1. Update workboard with completed work
2. Update MASTER_PLAN checkboxes if any phase items were completed
3. Do NOT leave orphaned plan files, status docs, or coordination artifacts

## Worktree Agents

Worktree agents (spawned via `isolation: "worktree"`) operate on isolated copies.
They MUST still read the hub workboard before starting and report results back.
Worktrees are automatically cleaned up if no changes are made.
If a worktree has uncommitted work when the agent crashes, the parent agent must
check for orphaned worktrees and recover or discard.

## Memory Architecture

- **Suite memory** (`~/.claude/projects/-home-joshua-v-dev-suite/memory/`): shared across suite repos
- Each project in the Suite has its own memory directory; do not cross-pollinate
