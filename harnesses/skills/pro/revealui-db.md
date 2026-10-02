# Database Conventions

## Primary Store: NeonDB (PostgreSQL)

RevealUI uses **NeonDB as the primary store** via Drizzle ORM. The schema lives in `packages/db/src/schema/` (86 tables across accounts, users, sites, posts, agents, RAG, billing, jobs, webhooks, audit, etc.). Migrations apply via standard `drizzle-kit migrate`.

Legacy `@supabase/supabase-js` code has been phased out from runtime — zero real `from '@supabase/supabase-js'` imports remain in `packages/` or `apps/`. **New features must not introduce a Supabase dependency.**

## Query Patterns (Drizzle ORM on Neon)

```ts
import { db } from '@revealui/db'
import { posts } from '@revealui/db/schema'

const results = await db.select().from(posts).where(eq(posts.status, 'published'))
```

## Vector / Embedding Storage

Vector embeddings (RAG, AI memory) live in NeonDB on the `pgvector` extension. HNSW indexes are created in `0002_triggers_search_vectors.sql`. Schemas: `rag_documents`, `rag_chunks`, `agent_memories.embedding`.

## Database MCP

Agent database tooling uses the Neon MCP launcher (`launchNeonMcp`). The legacy customer Supabase MCP adapter was removed; do not reintroduce `supabase-mcp` or `@supabase/supabase-js` as runtime dependencies.

Application persistence goes through `@revealui/db`. Extend its owning database client and schema; do not introduce parallel persistence clients or stores.

## Migration Discipline

See `packages/db/docs/migrations-discipline.md`. `pnpm validate:migrations` enforces journal/snapshot/idempotency invariants.

## Schema Change Workflow

1. Add or modify schema in `packages/db/src/schema/`
2. Run `pnpm --filter @revealui/db db:generate` (drizzle-kit will produce the SQL + snapshot)
3. Review the generated SQL — wrap any `ADD CONSTRAINT` in `DO $$ BEGIN ... END $$` for idempotency
4. Apply locally via `pnpm --filter @revealui/db db:migrate` (requires `POSTGRES_URL`)
5. Run `pnpm --filter @revealui/db test` to confirm nothing regressed
6. Commit migration + snapshot together