# Versioning Convention — Maturity-Driven Semver

## Pre-1.0: The Maturity Ladder

Before 1.0, the **minor** version signals the package's maturity stage. Patches are the default cadence for all normal work (features, fixes, refactors) within a stage.

**A minor bump is a promotion decision, not a side effect of a `feat()` commit.**

| Minor | Stage | Gate Criteria |
|-------|-------|---------------|
| `0.1.x` | **Scaffold** | Builds, exports types, basic functionality |
| `0.2.x` | **Functional** | Core API works, unit tests pass, consumed by at least 1 app |
| `0.3.x` | **Integrated** | Cross-package consumers work, integration tests exist |
| `0.4.x` | **Hardened** | Error paths tested, edge cases handled, zero `any` types |
| `0.5.x` | **Documented** | README complete, exported API has JSDoc, usage examples |
| `0.6.x` | **Secured** | Security audit passed, zero CodeQL alerts, input validation |
| `0.7.x` | **Battle-tested** | Running in production with real traffic, no P0 bugs |
| `0.8.x` | **API frozen** | No breaking changes planned, deprecation notices issued |
| `0.9.x` | **RC** | Only bug fixes, performance tuning, doc polish |
| `1.0.0` | **Stable** | Public API contract guaranteed |

## Post-1.0: Standard Semver

After 1.0, standard semantic versioning applies:
- **Patch** (1.0.x): bug fixes, dependency updates, internal refactors
- **Minor** (1.x.0): new backward-compatible features
- **Major** (x.0.0): breaking API changes (requires migration guide)

## Rules

1. **Patches are the default.** Bug fixes, new features, refactors, dependency updates — all patches within the current maturity tier.
2. **Minor bumps require a promotion decision.** Before bumping 0.N to 0.(N+1), verify the package meets ALL gate criteria for the new tier. This is a checklist, not a feeling.
3. **Packages move independently.** Each package has its own maturity clock. Do not promote packages in lockstep.
4. **Cascading deps stay on patch.** `updateInternalDependencies: "patch"` — a consumer does not bump minor just because a dependency did.
5. **Contracts (post-1.0) follows standard semver.** New schema fields = minor. Removed/renamed fields = major. Fixes = patch.
6. **Changeset descriptions explain what changed**, not the bump rationale. The bump type is the rationale.

## Promotion Checklist

Before promoting a package to the next minor tier, verify:

```
[ ] All gate criteria for the new tier are met (see table above)
[ ] Previous tier criteria are still met (they stack)
[ ] CHANGELOG entry explains the promotion
[ ] No known regressions or open P0 bugs against this package
```

## Publish Workflow

The release pipeline has three stages:

1. **Create changesets** — `pnpm changeset` in the working branch. One changeset per logical group of changes.
2. **Version** — `pnpm changeset:version` bumps package.json versions, generates CHANGELOGs, runs `pnpm install --no-frozen-lockfile` to update the lockfile.
3. **Publish** — Two paths:
   - **Canary** (automatic): `release-canary.yml` runs on every push to `test`. Publishes snapshot versions (`@canary` dist-tag) if changesets exist.
   - **Stable** (manual): `release.yml` is `workflow_dispatch` only. Builds, validates artifacts, generates SBOM, publishes with OIDC provenance, creates GitHub releases.

**After `changeset:version`, commit the version bump before pushing.** The canary workflow consumes changeset files — if they're gone (already versioned), canary skips. If they're present, canary publishes snapshots.

## Changeset Config

Key settings in `.changeset/config.json`:

- `updateInternalDependencies: "patch"` — cascading patch bumps only
- `baseBranch: "main"` — changesets compares against main
- `ignore` list includes all apps, Pro packages (ai, harnesses), and non-publishable packages

**Pro packages (ai, harnesses) are ignored** — they're gitignored in the public repo and versioned separately from the private repo.

## Internal Dependencies

All intra-workspace dependencies use `workspace:*` (regular deps), never `peerDependencies`.
Internal `@revealui/*` peer deps were eliminated — they caused major-version cascades on
changeset version bumps. See memory: `project_peer_dep_cascade_fix.md`.

## When in Doubt

If unsure whether a change warrants a minor bump: **use patch**. You can always promote later. You cannot unpublish a minor.
