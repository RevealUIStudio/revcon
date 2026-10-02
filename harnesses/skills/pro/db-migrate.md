# Database Migration Workflow

Guide for creating and reviewing Drizzle ORM migrations through the single Neon-primary PostgreSQL store. Apply migrations only within the authorized development/release workflow.

## Pre-Flight Checks

Before creating a migration:

1. **Use the owning persistence boundary**:
   - All application persistence goes through `@revealui/db` and its Drizzle schema, including sessions and pgvector data
   - Inspect the current exports in `packages/db/src/schema/`; vector tables use the same PostgreSQL client
   - Do not introduce a second database, vector/auth SDK, or Supabase runtime client

2. **Check existing schema** for conflicts:
   ```bash
   # View current schema files
   ls packages/db/src/schema/

   # Check for table name conflicts
   grep -r "export const.*pgTable" packages/db/src/schema/
   ```

3. **Verify contracts alignment**  -  new tables/columns should have corresponding Zod schemas:
   ```bash
   ls packages/contracts/src/
   ```

## Migration Steps

### Step 1: Modify Schema

Edit the appropriate schema file in `packages/db/src/schema/`:

- Follow existing patterns (see adjacent schema files)
- Use Drizzle's `pgTable`, column types, and relations
- Add indexes for frequently queried columns
- Add `createdAt`/`updatedAt` timestamps with defaults

### Step 2: Generate Migration

```bash
cd packages/db
pnpm drizzle-kit generate
```

Review the generated SQL in `packages/db/drizzle/`  -  check for:
- Destructive changes (DROP TABLE, DROP COLUMN)
- Data loss risks (column type changes without USING clause)
- Missing indexes on foreign keys

### Step 3: Apply Migration (Development Only)

```bash
# Development database ONLY  -  never production
pnpm db:migrate
```

**NEVER run `drizzle-kit push`**  -  always use `drizzle-kit migrate` (the PreToolUse hook blocks `push`).

### Step 4: Verify

```bash
# Typecheck the db package
pnpm --filter @revealui/db typecheck

# Run db tests
pnpm --filter @revealui/db test

# If schema changes affect contracts, update and test those too
pnpm --filter @revealui/contracts typecheck
pnpm --filter @revealui/contracts test
```

### Step 5: Update Contracts (if needed)

If you added new tables or columns that are exposed via the API:

1. Add/update Zod schema in `packages/contracts/src/`
2. Export from `packages/contracts/src/index.ts`
3. Update any API routes that use the new schema

## Persistence Boundary

| If your change touches... | Owning schema | Client |
|---------------------------|---------------|--------|
| Content, users, sessions, products, orders | `packages/db/src/schema/` | `@revealui/db` Drizzle client |
| Vector embeddings, AI memory | `packages/db/src/schema/vector.ts` | The same `@revealui/db` Drizzle client |

Auth/session behavior belongs to `packages/auth/` and uses the owning database boundary. Extend that primitive instead of creating a parallel store or auth client.

## Rollback

If a migration needs to be reverted:

1. Create a new migration that undoes the changes (Drizzle doesn't have built-in rollback)
2. Never manually edit the migration journal (`_journal.json`)
3. Document the rollback reason in the migration file comment