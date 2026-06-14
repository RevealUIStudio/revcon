# Git Conventions

## Commit Messages
- Use conventional commits: `type(scope): description`
- Types: feat, fix, refactor, docs, test, chore, ci, perf
- Scope is optional, use package name for monorepos (e.g., `feat(core): add parser`)
- Description in imperative mood, lowercase, no period
- Keep subject line under 72 characters

## Branch Naming
- Feature: `feat/<short-description>` or `feat/<issue#>-<short-description>`
- Bugfix: `fix/<short-description>` or `fix/<issue#>-<short-description>`
- Chore: `chore/<short-description>` or `chore/<issue#>-<short-description>`
- When fixing a GitHub issue, include the issue number in the branch name

## Issue → PR → Close Workflow
- PRs that fix a GitHub issue MUST include `Closes #N` in the PR description
- Place `Closes #N` at the top of the PR body (the template prompts for it)
- GitHub auto-closes the issue when the PR merges to main
- One PR can close multiple issues: `Closes #1, Closes #2`

## Identity
- Professional repos (RevealUIStudio): RevealUI Studio <founder@revealui.com>
