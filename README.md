# editor-configs

Private registry of editor and tooling configurations for RevealUI projects.

## Supported editors

- cursor/ - Cursor IDE
- zed/ - Zed editor
- vscode/ - VS Code (placeholder)

## Usage

Apply configs to an existing project:

    git clone git@github.com:RevealUIStudio/editor-configs.git /tmp/editor-configs
    /tmp/editor-configs/scripts/apply.sh --editor cursor --target /path/to/project

Or apply all editors:

    /tmp/editor-configs/scripts/apply.sh --target /path/to/project

### apply.sh flags

- --editor cursor|zed|vscode|all (default: all)
- --target /path (default: current directory)

## What is included

### Cursor (cursor/)

- config.json - AI rules, file patterns, framework context
- environment.json - Terminal setup using FNM, Node 24 (replaces NVM)
- mcp-config.json - MCP server definitions (Vercel, Stripe, Neon, Supabase, Playwright)
- mcp.json - Vite dev server MCP endpoint
- rules.md - Cursor AI coding rules
- rules/node-version.mdc - Node version enforcement
- commands/ - Custom Cursor commands
- snippets/ - Code snippets (React, Next.js, route handlers)
- workflows/ - Development workflow docs

### Zed (zed/)

- settings.json - Zed workspace settings
- tasks.json - Zed task definitions

## After applying

1. Review all copied files
2. environment.json uses FNM - install fnm if not present (https://github.com/Schniz/fnm)
3. mcp-config.json env vars use dollar{VAR} placeholders - set in .env.local or shell
4. mcp-config.json references pnpm mcp:* scripts - verify in target package.json
5. Commit the editor config files if you want them tracked in the project

## CLI integration

The create-revealui CLI will offer --with-editor-configs as an optional step during
project scaffolding, cloning this repo and running apply.sh automatically.
