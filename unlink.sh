#!/usr/bin/env bash
# unlink.sh — Remove symlinked editor configs from a target project.
#
# Usage:
#   ./unlink.sh --target ~/revfleet/revealui
#   ./unlink.sh --target ~/revfleet/revealui --editor zed
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
SKIP_EDITORS="${REVCON_SKIP_EDITORS:-}"
PRIVATE_PROFILES_DIR="${REVCON_PRIVATE_PROFILES_DIR:-}"

usage() {
  cat <<'EOF'
Usage: unlink.sh [OPTIONS]

Options:
  --target DIR     Project directory to unlink from (required)
  --editor NAME    Editor to unlink: cursor, zed, vscode, claude, agents, all (default: all)
  --skip NAME      Skip a specific editor (repeatable, comma-separated also works)
  --dry-run        Show what would be done without making changes
  -h, --help       Show this help

Environment variables:
  REVCON_SKIP_EDITORS         Comma-separated editors to skip by default
  REVCON_PRIVATE_PROFILES_DIR Also remove symlinks pointing into this directory
                              (in addition to symlinks pointing into the revcon repo)
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)  TARGET="$2";  shift 2 ;;
    --editor)  EDITOR="$2";  shift 2 ;;
    --skip)    SKIP_EDITORS="${SKIP_EDITORS:+$SKIP_EDITORS,}$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

should_skip_editor() {
  local e="$1"
  [[ -z "$SKIP_EDITORS" ]] && return 1
  [[ ",$SKIP_EDITORS," == *",$e,"* ]]
}

is_revcon_link() {
  local dest="$1"
  [[ "$dest" == "$SCRIPT_DIR"* ]] && return 0
  [[ -n "$PRIVATE_PROFILES_DIR" && "$dest" == "$PRIVATE_PROFILES_DIR"* ]] && return 0
  return 1
}

if [[ -z "$TARGET" ]]; then
  echo "Error: --target is required"
  exit 1
fi

TARGET="$(realpath "$TARGET")"

declare -A EDITOR_DIRS=(
  [cursor]=".cursor"
  [zed]=".zed"
  [vscode]=".vscode"
  [claude]=".claude"
  [agents]=".agents"
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
    # Remove symlinks pointing into the revcon repo OR a configured private profiles dir
    if is_revcon_link "$dest"; then
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
  for e in cursor zed vscode claude agents; do
    if should_skip_editor "$e"; then
      echo "[$e] skipped (REVCON_SKIP_EDITORS / --skip)"
      continue
    fi
    unlink_editor "$e"
  done
else
  if should_skip_editor "$EDITOR"; then
    echo "[$EDITOR] skipped (REVCON_SKIP_EDITORS / --skip)"
  else
    unlink_editor "$EDITOR"
  fi
fi

echo ""
echo "Done: $REMOVED symlinks removed"
echo "Note: .gitignore entries preserved (safe to keep)"
