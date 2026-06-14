# Model & Effort Allocation (token economy)

Quota weight per token: Fable ≈ 2x Opus ≈ 3.3x Sonnet ≈ 10x Haiku. Most tokens flow through the MAIN loop — pick its model once per session and push breadth work into tiered subagents. Verified mechanics + sources: Windows-instance memory `reference_claude_code_cost_mechanics` (2026-06-12).

## Session start (set once — mid-session `/model` or `/effort` rebuilds the prompt cache)
- Execution-heavy session: `/model sonnet`, effort high.
- Design / audit-synthesis / hard-debug session: opus (fable only when the extra tier is truly warranted).
- `opusplan` fits mixed days (Opus plans, Sonnet executes) — note each plan-mode toggle is a model switch (cache rebuild).
- **Never `/fast`** — it bills usage credits from the first token even with plan quota remaining.

## Delegation tiers (custom agents are pinned via frontmatter)
- **mechanic** (haiku): renames, moves, format fixes, lockfile regen, doc-only edits, locate-files. (Haiku has no effort knob — the param errors on Haiku 4.5.)
- **Explore** (pass `model: haiku|sonnet`): sweeps, inventories, CI-log triage — ask for conclusions, not file dumps.
- **implementer** (sonnet): spec'd features, fixes, tests.
- **reviewer** (opus) / **senior-architect** (opus, effort xhigh): review, audits, architecture.
- Keep haiku OFF the main loop — a haiku main loop loses MCP tool deferral (all schemas load upfront).
- Delegation has fixed overhead (subagents start cold on a 5-min cache TTL; tens of k tokens): delegate chunky work, do single-file reads inline.

## Session hygiene
- `/clear` between unrelated lanes — stale context re-bills every turn.
- `/compact` at phase boundaries with keep-instructions (e.g. `/compact keep file paths, branch names, open PRs`), not mid-task auto-compact. `/rewind` over re-explaining (reuses the cached prefix).
- `/usage` = plan bars + per-component burn attribution (skills/subagents/MCP); `/context` = MCP overhead audit.
- Agent teams ≈ 7x a normal session; Workflow fan-outs only with an explicit token budget.
- Editing CLAUDE.md/rules mid-session does NOT invalidate the cache (applies on next restart/clear) — config trims are safe anytime.

## Session handoff loop (replaces stack-and-consolidate)
- **ONE rolling handoff**: `~/revfleet/.jv/docs/handoffs/CURRENT-HANDOFF.md`. At session end, `/checkpoint` MERGES this session's delta into it (sections: done+verified / in-flight / ordered next actions / owner-gated). The ending session already holds the context, so the merge is near-free; a separate consolidation session pays ~15k tokens of fixed overhead plus the whole checkpoint stack as cold input. **Never stack checkpoints in a side file for later consolidation.**
- End every session with the archive-readiness next-agent prompt (`reference/archive-readiness.md` on the Windows tree) pointing at CURRENT-HANDOFF.md.
- Finisher sessions start on `/model sonnet` from that prompt and read CURRENT-HANDOFF.md — never a checkpoint stack.
- When CURRENT-HANDOFF.md exceeds ~150 lines, the ending session prunes shipped items to `docs/handoffs/archive/` as part of checkpoint (same pattern as the workboard >200-line sweep).
- If a batch consolidation is ever genuinely needed, it is a sonnet job (subagent or `/model sonnet` session) — never flagship.
