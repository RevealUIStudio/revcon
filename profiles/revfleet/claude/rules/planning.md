# Planning Convention

## Per-repo planning

This repo's `docs/MASTER_PLAN.md` is a **scoped snapshot** — it covers only this
repo and defers to the fleet master on any cross-cutting question. It is not the
single source of truth for the fleet.

Fleet-level cross-cutting plans, lane state, and roadmap tracking live in the
internal coordination hub (the agent dev environment), not in a public repo (see
this repo's `docs/INDEX.md` "Fleet coordination"). Per-endeavor, multi-session
work is tracked as a lane in that hub, not as a loose plan file.

Session plan files in `~/.claude/plans/` are ephemeral scratch — do not treat as
durable, and do not promote them into a repo's `docs/`.
