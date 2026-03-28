#!/usr/bin/env bash
# unlink.sh — Remove symlinked editor configs from a target project.
#
# Usage:
#   ./unlink.sh --target ~/projects/RevealUI
#   ./unlink.sh --target ~/projects/RevealUI --editor zed
#
# Removes only symlinks that point back into this editor-configs repo.
# Real files (local overrides, editor state) are left untouched.
# Empty directories are cleaned up. Gitignore entries are NOT removed
# (harmless to keep, avoids accidental commits if re-linking later).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET=""
EDITOR="all"
DRY_RUN=false

usage() {
  cat <<'EOF'
Usage: unlink.sh [OPTIONS]

Options:
  --target DIR     Project directory to unlink from (required)
  --editor NAME    Editor to unlink: cursor, zed, vscode, all (default: all)
  --dry-run        Show what would be done without making changes
  -h, --help       Show this help
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)  TARGET="$2";  shift 2 ;;
    --editor)  EDITOR="$2";  shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

if [[ -z "$TARGET" ]]; then
  echo "Error: --target is required"
  exit 1
fi

TARGET="$(realpath "$TARGET")"

declare -A EDITOR_DIRS=(
  [cursor]=".cursor"
  [zed]=".zed"
  [vscode]=".vscode"
)

REMOVED=0

unlink_editor() {
  local editor="$1"
  local dot_dir="${EDITOR_DIRS[$editor]}"
  local target_dir="$TARGET/$dot_dir"

  if [[ ! -d "$target_dir" ]]; then
    return
  fi

  echo "[$editor] scanning $target_dir"

  while IFS= read -r -d '' link; do
    local dest
    dest="$(readlink "$link")"
    # Only remove symlinks that point into our repo
    if [[ "$dest" == "$SCRIPT_DIR"* ]]; then
      if $DRY_RUN; then
        echo "  [remove] $link → $dest"
      else
        rm "$link"
        echo "  [remove] $(basename "$link")"
      fi
      ((REMOVED++)) || true
    fi
  done < <(find "$target_dir" -type l -print0 2>/dev/null)

  # Clean up empty subdirectories (bottom-up)
  if ! $DRY_RUN; then
    find "$target_dir" -type d -empty -delete 2>/dev/null || true
  fi
}

echo "Unlinking editor configs from $TARGET"
$DRY_RUN && echo "(dry run)"
echo ""

if [[ "$EDITOR" == "all" ]]; then
  for e in cursor zed vscode; do
    unlink_editor "$e"
  done
else
  unlink_editor "$EDITOR"
fi

echo ""
echo "Done: $REMOVED symlinks removed"
echo "Note: .gitignore entries preserved (safe to keep)"
