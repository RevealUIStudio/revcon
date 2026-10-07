# Agent Profile Dispatch

Profiles live in `.revealui/content/agents/`. Spawn them via the Agent tool when a task is
too large or specialized for the current session.

## Profiles

| Profile | When to spawn |
|---------|--------------|
| `gate-runner` | Running the full CI gate (`pnpm gate`), verifying the repo is clean before a push or release |
| `security-reviewer` | Auditing auth flows, reviewing security-sensitive PRs, checking new API routes for vulnerabilities |
| `builder` | Building and typechecking specified packages; diagnosing build failures without changing source |
| `tester` | Running test suites and coverage; reporting failures and suggested fixes without changing source |
| `docs-sync` | Checking documentation against code and reporting drift; no file or planning edits |
| `linter` | Bulk lint fixes, unused declaration sweeps, `any` type removal, Biome cleanup across the monorepo |

## Rules

1. Don't spawn a profile for work that takes under 15 minutes in the current session.
2. Check the workboard before spawning  -  another agent may already own that area.
3. Always give spawned agents:
   - Current phase from the internal planning hub's MASTER_PLAN.md
   - Relevant workboard state
   - The specific task and acceptance criteria
4. Spawned agents report findings back to the parent. Only the parent updates MASTER_PLAN.md.
5. Builder, tester, docs-sync, and gate-runner are validation profiles. Implementation, test writing, and documentation edits stay with the parent or an explicitly authorized editing agent; do not assign them to report-only profiles.
6. Spawned agents must not create plan files outside MASTER_PLAN.md (see `planning.md`).