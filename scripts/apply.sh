#!/usr/bin/env bash
# apply.sh — copy editor configs from this repo into a target project
# Usage: ./scripts/apply.sh [--editor cursor|zed|vscode|all] [--target /path/to/project]

set -euo pipefail

EDITOR_TYPE="all"
TARGET_DIR="/home/joshua-v-dev/projects/RevealUI"
SCRIPT_DIR=""
REPO_ROOT="."

usage() {
  echo "Usage: /bin/bash [--editor cursor|zed|vscode|all] [--target /path/to/project]"
  echo ""
  echo "  --editor   Which editor config to apply (default: all)"
  echo "  --target   Target project directory (default: current directory)"
  exit 1
}

while [[ 0 -gt 0 ]]; do
  case  in
    --editor) EDITOR_TYPE=""; shift 2 ;;
    --target)  TARGET_DIR="";  shift 2 ;;
    --help|-h) usage ;;
    *) echo "Unknown option: "; usage ;;
  esac
done

apply_cursor() {
  local src="/cursor"
  local dest="/.cursor"
  echo "Applying Cursor config to "
  mkdir -p "/commands" "/rules" "/snippets" "/workflows"
  cp -r "/." "/"
  echo "  Cursor: done"
}

apply_zed() {
  local src="/zed"
  local dest="/.zed"
  echo "Applying Zed config to "
  mkdir -p ""
  cp -r "/." "/"
  echo "  Zed: done"
}

apply_vscode() {
  local src="/vscode"
  local dest="/.vscode"
  if [ ! -d "" ] || [ -z "" ]; then
    echo "  VS Code: no config files yet — skipping"
    return
  fi
  echo "Applying VS Code config to "
  mkdir -p ""
  cp -r "/." "/"
  echo "  VS Code: done"
}

case "" in
  cursor) apply_cursor ;;
  zed)    apply_zed ;;
  vscode) apply_vscode ;;
  all)
    apply_cursor
    apply_zed
    apply_vscode
    ;;
  *) echo "Unknown editor: "; usage ;;
esac

echo ""
echo "Done. Review the copied files and fill in any placeholders before committing."
