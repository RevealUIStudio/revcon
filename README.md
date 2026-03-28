# editor-configs

Centralized editor configurations for RevealUI projects. Configs are symlinked
into target projects — edits propagate instantly, nothing gets committed to
target repos.

## Quick Start

```bash
# Link into a project with a profile
./link.sh --target ~/projects/RevealUI --profile revealui

# Link base configs only (no profile)
./link.sh --target ~/projects/RevealCoin

# Link a single editor
./link.sh --target ~/projects/RevealUI --profile revealui --editor zed

# Preview without changes
./link.sh --dry-run --target ~/projects/RevealUI --profile revealui

# Remove symlinks
./unlink.sh --target ~/projects/RevealUI

# List available profiles
./link.sh --list
```

## Structure

```
editor-configs/
├── base/                          # Universal configs (all projects)
│   ├── cursor/
│   │   ├── .cursorignore
│   │   ├── environment.json
│   │   └── snippets/
│   └── zed/
│       └── settings.json
├── profiles/                      # Per-project overrides (layered on base)
│   └── revealui/
│       ├── cursor/
│       │   ├── .cursorrules
│       │   ├── config.json
│       │   ├── mcp-config.json
│       │   ├── rules.md
│       │   ├── commands/
│       │   └── workflows/
│       └── zed/
│           └── tasks.json
├── link.sh                        # Create symlinks + gitignore
└── unlink.sh                      # Remove symlinks
```

## How It Works

1. **`link.sh`** creates real directories (`.zed/`, `.cursor/`) in the target project
2. Individual config files are symlinked from `base/` into those directories
3. Profile files overlay on top — same filename in a profile overrides the base version
4. Editor-written state (cache, chat history) stays in the real directory, not here
5. `.gitignore` is updated so symlinked dirs are never committed

## Adding a Profile

```bash
mkdir -p profiles/revealcoin/cursor profiles/revealcoin/zed
# Add project-specific configs (MCP servers, tasks, rules, etc.)
```

## Supported Editors

| Editor | Dot-dir | Status |
|--------|---------|--------|
| Cursor | `.cursor/` | Full support |
| Zed | `.zed/` | Full support |
| VS Code | `.vscode/` | Placeholder |

## License

MIT
