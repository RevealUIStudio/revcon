# RevealUI Safety

Follow these rules for ALL code changes in the RevealUI monorepo.

## Protected Files  -  Ask Before Editing

- `.env*` files (`.env`, `.env.local`, `.env.production`, etc.)
- Lock files: `pnpm-lock.yaml`, `package-lock.json`, `yarn.lock`
- Database schema files in `packages/db/src/schema/`  -  changes require migration planning

## Protected Paths  -  Never Edit

- Windows host mounts (typically `/mnt/c/`) and the LTS backup mount (`$LTS_ROOT`, typically `/mnt/e/`)  -  read-only
- System/credential directories: `/etc/`, `~/.ssh/`, `~/.gnupg/`, `~/.aws/`

## Database Imports

`@supabase/supabase-js` has been phased out from internal runtime — do not reintroduce it as a runtime dependency. NeonDB (via `@revealui/db` + Drizzle) is the primary store. The legacy customer Supabase MCP adapter was also removed; do not re-add `supabase-mcp` launchers.

Application persistence goes through `@revealui/db`. Extend its owning database client and schema; do not introduce parallel persistence clients or stores.

## Code Quality

- Never use `any`  -  use `unknown` + type guards
- Never add `console.*` in production code  -  use `@revealui/utils` logger
- Never hardcode API keys, tokens, passwords, or secrets
- Use `crypto.randomInt()` for security-sensitive values, not `Math.random()`

## Static Analysis

- For security and architecture validation scripts, prefer AST-based analysis over regex when the rule depends on syntax or code shape
- Use regex only for heuristic inventory scans (for example obvious secret patterns), not as the source of truth for code-security conclusions

## After Every Edit

Run `npx biome check --write <file>` on each file you edit before moving on.

## Before Claiming Done

1. Run `pnpm gate:quick` and confirm no new errors
2. Review `git diff` for unintended changes
3. Ensure conventional commit format: `type(scope): description`
4. Git identity: Use the committer's own verified GitHub noreply identity from the supported Git configuration; do not substitute another author.

## Known Limitation

These rules are advisory. Unlike Claude Code (which enforces via lifecycle hooks), Codex has no hook system. If working on sensitive files, explicitly invoke `$revealui-safety` to load these rules.