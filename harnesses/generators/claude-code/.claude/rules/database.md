# Database Conventions

## Database Architecture

RevealUI runs a **single Neon-primary PostgreSQL database** (Drizzle ORM), with vector data (agent memories + RAG) stored in that same database via pgvector and live sync provided by ElectricSQL:

| Database | Client | Purpose |
|----------|--------|---------|
| **Neon** (PostgreSQL) | `@neondatabase/serverless` (falls back to `node-postgres` for localhost) | All data: collections, users, sessions, orders, products, plus pgvector tables (agent memories, RAG) |
| **ElectricSQL** | `@electric-sql` | Live read-path sync over the same Neon database |

## Boundary Rule

There is no second database client. All persistence goes through the single Drizzle/Neon client (`@revealui/db`); vector data lives in pgvector on the same Neon database, so there is no separate vector/auth client to import. (A customer-facing Supabase MCP adapter exists for connecting a customer's OWN Supabase project as a selectable data source — it is never RevealUI's internal store.)

## Schema Organization

```
packages/db/src/schema/
├── accounts.ts       # NeonDB: user accounts
├── agents.ts         # NeonDB: AI agent definitions
├── api-keys.ts       # NeonDB: API key management
├── admin.ts          # NeonDB: admin collections, media
├── gdpr.ts           # NeonDB: GDPR consent, deletion
├── licenses.ts       # NeonDB: license keys, tiers
├── pages.ts          # NeonDB: pages, navigation
├── sites.ts          # NeonDB: multi-tenant sites
├── tickets.ts        # NeonDB: support tickets
├── users.ts          # NeonDB: user management, sessions
├── vector.ts         # Neon (pgvector): embeddings, agent memory, RAG
├── rest.ts           # NeonDB: REST schema barrel
├── index.ts          # Combined schema export
└── ...               # 30+ schema files total
```

## Query Patterns

### NeonDB (Drizzle ORM)
```ts
import { db } from '@revealui/db'
import { posts } from '@revealui/db/schema'

const results = await db.select().from(posts).where(eq(posts.status, 'published'))
```

### Vector queries (pgvector on Neon)
```ts
// Vector tables live on the same Neon database (pgvector)
import { db } from '@revealui/db'
import { agentMemories } from '@revealui/db/schema'

const results = await db.select().from(agentMemories).orderBy(cosineDistance(agentMemories.embedding, queryEmbedding)).limit(5)
```

## Enforcement

The `pnpm validate:structure` script checks package/import-boundary conventions.
CI runs this as part of phase 1 (warn-only — violations are flagged but don't block builds).

To check locally:
```bash
pnpm validate:structure
```

## Migration Guidance

When adding new features:
1. **Content/REST data** → add to `packages/db/src/schema/` + use Drizzle
2. **AI/vector data** → add to `packages/db/src/schema/vector.ts` (pgvector on the same Neon database) + use Drizzle
3. There is a single DB client — no cross-client mixing concern
