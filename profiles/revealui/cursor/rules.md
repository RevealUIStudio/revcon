---
alwaysApply: true
---

# RevealUI Framework - Cursor IDE Rules

**Note (2026-05-29):** Authoritative agent rules live in `~/.claude/rules/` and `.claude/rules/`. The architecture map below was reconciled with the RevealUI monorepo (`apps/*` + `packages/*`) on 2026-05-29.

## Project Overview
RevealUI is a framework built with:
- **React 19** with React Compiler
- **Next.js 16** (admin app)
- **@revealui/core** (Native admin framework)
- **@revealui/db** (Drizzle ORM)
- **TypeScript** (strict mode)
- **Tailwind CSS 4.0**
- **Monorepo** structure (pnpm workspaces)

## Architecture

Monorepo (pnpm workspaces): `apps/*` + `packages/*`.

**Apps** (`apps/`):
- `admin` - Next.js 16 admin dashboard, built on @revealui/core (Turbopack, standalone output)
- `server` - REST API server with OpenAPI spec + Swagger UI
- `marketing` - Marketing site (homepage, blog, pricing, contact)
- `docs` - Documentation site

**Packages** (`packages/`, alphabetical):
- `@revealui/ai` - AI runtime (Fair Source): agents, memory, open-model LLM providers, tools, orchestration; Anthropic-SDK-free
- `@revealui/auth` - DB-backed session auth for Hono + Next.js (bcrypt, OAuth, brute-force protection, rate limiting, password reset)
- `@revealui/cache` - Framework-agnostic CDN config, edge cache, ISR presets, revalidation
- `@revealui/cli` - Scaffolds new RevealUI projects
- `@revealui/config` - Type-safe env configuration with Zod validation + lazy proxy
- `@revealui/contracts` - Single source of truth for Zod schemas + shared TypeScript types
- `@revealui/core` - Runtime engine: admin UI, REST API, auth, rich text, plugins, access control
- `create-revealui` - Project initializer (`npm create revealui`)
- `@revealui/db` - Drizzle ORM schema (85 tables) on NeonDB (Postgres)
- `@revealui/dev` - Internal dev config (Biome, TypeScript, Tailwind, Vite, PostCSS); not published
- `@revealui/engines` - Unified entry for the five business primitives: users, content, products, payments, intelligence
- `@revealui/harnesses` - AI harness integration: adapters, daemon, workboard coordination, JSON-RPC
- `@revealui/mcp` - Model Context Protocol framework: server hypervisor, tool discovery, adapters (Stripe, Vercel)
- `@revealui/openapi` - Type-safe OpenAPI 3.x for Hono (route defs, Zod middleware, spec generation)
- `@revealui/paywall` - Runtime license enforcement, feature gating, upgrade UI
- `@revealui/presentation` - Native React UI components on Tailwind v4
- `@revealui/resilience` - Circuit breaker, retry, bulkhead, timeout (DB-backed circuit state)
- `revealui` - Meta-installer that proxies to create-revealui (not published)
- `@revealui/router` - File-based React router (SSR, loaders, middleware, nested layouts)
- `@revealui/scripts` - Shared monorepo-script utilities (glob, JSON parse, logging)
- `@revealui/security` - CSP/CORS/HSTS headers, RBAC + ABAC policy engine, encryption, audit logging, GDPR
- `@revealui/services` - External integrations: Stripe (billing) and Vercel (deploy/DNS)
- `@revealui/setup` - New-project setup: env config, DB init, secrets validation (used by the CLI)
- `@revealui/sync` - Real-time sync over ElectricSQL + Yjs CRDT (offline queue, conflict resolution, collaborative docs)
- `test` - E2E (Playwright), integration tests, fixtures, mocks, test utilities
- `@revealui/utils` - Shared utilities: logger, SSL config, validation helpers

## Key Conventions

### Terminal Commands
- **NEVER pipe development server commands** like `pnpm dev` through `head`, `tail`, or other output limiters
- Development servers (`pnpm dev`, `npm run dev`, etc.) are long-running processes - let them run continuously
- To check for startup errors only, use `timeout 10s pnpm dev` without pipes
- For background execution, use `pnpm dev &` not `pnpm dev 2>&1 | head -20`

### Package Manager
- **ALWAYS use `pnpm dlx` instead of `npx`** in package.json scripts and code
- Exception: `preinstall` scripts may use `npx only-allow pnpm` (runs before pnpm installs)
- Use `pnpm` for all package management commands
- This prevents npm deprecation warnings and enforces pnpm usage

### Import Paths
- Use `@/lib/*` for admin app imports
- Use `@revealui/core` for admin framework imports
- Use `@revealui/db` for database imports
- Use `@revealui/contracts` for Zod schemas and validation
- Use workspace protocol for internal packages: `workspace:*`

### TypeScript
- Strict mode enabled
- Prefer explicit types over `any`
- Use `Config` type from `@revealui/core` for admin configs
- Use `CollectionConfig` for collection definitions

### API Architecture
- **NEVER use GraphQL** - RevealUI uses REST APIs and RPC (Remote Procedure Calls) exclusively
- Use REST API handlers from `@revealui/core/api/rest`
- RPC is supported for type-safe procedure calls
- All API endpoints use standard HTTP methods (GET, POST, PATCH, DELETE)
- GraphQL is forbidden - do not add GraphQL dependencies, schemas, or resolvers

### Admin Routes
- All dynamic routes must be marked `export const dynamic = "force-dynamic"`
- Use `createRevealUI` for admin initialization
- Collections with `auth: true` automatically handle authentication

### Next.js 16
- `params` and `searchParams` are Promises - await them
- Use `export const dynamic = "force-dynamic"` for dynamic routes
- `experimental.instrumentationHook` is deprecated
- Use `images.remotePatterns` instead of `images.domains`

### Environment Variables
- `.env` files are tracked in git (production values generated in CI/CD)
- Use `REVEALUI_SECRET` for encryption (required for builds)
- Use `POSTGRES_URL` for NeonDB connection
- SQLite adapter used as fallback when Postgres not available

## Code Style
- Use functional components with hooks
- Prefer named exports
- Use async/await over promises
- Add JSDoc comments for public APIs
- Use TypeScript interfaces for props

## Testing
- Vitest for unit tests
- Playwright for E2E tests
- Test files: `*.test.ts` or `*.spec.ts`
- Place tests next to source files or in `__tests__` folders

## Build & Development
- `pnpm dev` - Start all apps in development
- `pnpm build` - Build all packages
- `pnpm --filter admin build` - Build admin app
- Prefer Turbopack over Webpack for Next.js builds (use `--turbo` flag)

## Common Issues & Solutions

### Admin Build Errors
- Ensure `REVEALUI_SECRET` is set during build
- Ensure `POSTGRES_URL` is set for database connection
- All admin routes must be dynamic
- SQLite adapter used when Postgres unavailable

### TypeScript Errors
- Check import paths match actual file structure
- Ensure types are imported from correct packages
- Use `as` assertions sparingly, prefer proper types

### Next.js 16 Migration
- Update `params` and `searchParams` to Promises
- Remove deprecated `experimental.instrumentationHook`
- Use `images.remotePatterns` instead of `images.domains`

## File Organization
- Components: `src/lib/components/`
- Collections: `src/lib/collections/`
- Utilities: `src/lib/utilities/`
- Hooks: `src/lib/hooks/`
- Types: `src/types/`

## Git Workflow
- `.env` files are tracked (production values in CI/CD)
- Use conventional commits
- Run `pnpm lint` and `pnpm typecheck` before committing

---

## Agent-Specific Rules

**Status**: 🔴 **MANDATORY - ENFORCED**
**Last Updated**: 2026-05-08

### Rule #1: Legacy Code Removal (TOP PRIORITY)

**ALL IMPLEMENTATIONS MUST BE CURRENT. LEGACY/DEPRECATED CODE MUST BE REFACTORED TO USE NEW IMPLEMENTATIONS AND OLD CODE REMOVED.**

This is the **#1 priority** for every agent interaction.

**Before Every Change:**

1. Search for deprecated/legacy code in the affected area
2. Identify new implementations that should be used
3. Refactor all code to use new implementations
4. Remove all old/deprecated code
5. Verify no references to old code remain

**Never:**

- ❌ Leave old code "for backward compatibility"
- ❌ Create compatibility layers
- ❌ Mark code as deprecated without removing it
- ❌ Defer legacy code removal "for later"

**Always:**

- ✅ Remove old code immediately
- ✅ Refactor all call sites in the same change
- ✅ Use only current implementations
- ✅ Remove deprecated code as part of every change

### Rule #2: No Backward Compatibility

- Do not maintain old code paths
- Do not add compatibility layers
- Do not keep deprecated functions
- All code must use current implementations only

### Rule #3: Immediate Migration

When new implementations are created:

1. Find all usages of old code
2. Refactor all call sites
3. Remove old code
4. All in the same PR/commit

### Rule #4: Code Quality

- No `as any` type assertions
- No `@ts-ignore` comments
- Proper error handling
- Input validation
- TypeScript strict mode

### Rule #5: Testing

- Write tests for new code
- Update tests when refactoring
- Remove tests for removed code
- All tests must pass

### Rule #6: Documentation

- Update docs when removing code
- Document migration paths
- Remove references to old code
- Keep docs current

### Enforcement

**Every agent interaction must follow these rules. No exceptions.**

If you find legacy code, you MUST refactor it as part of your current task. Do not create separate migration tasks. Do not defer removal.
