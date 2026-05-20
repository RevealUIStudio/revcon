#!/usr/bin/env bash
# link.sh — Symlink editor configs into a target project.
#
# Usage:
#   ./link.sh --target ~/revfleet/revealui --profile revealui
#   ./link.sh --target ~/revfleet/revealcoin                    # base only
#   ./link.sh --target ~/revfleet/revealui --editor zed         # zed only
#   ./link.sh --list                                            # show available profiles
#
# Creates real directories (.zed/, .cursor/, .claude/, .agents/) in the target,
# then symlinks individual config files from base/ and optionally a profile overlay.
# Profile files override base files where filenames overlap.
# Adds symlinked dirs to the target's .gitignore.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET=""
PROFILE=""
EDITOR="all"
DRY_RUN=false
SKIP_EDITORS="${REVCON_SKIP_EDITORS:-}"
PRIVATE_PROFILES_DIR="${REVCON_PRIVATE_PROFILES_DIR:-}"

usage() {
  cat <<'EOF'
Usage: link.sh [OPTIONS]

Options:
  --target DIR     Project directory to link into (required)
  --profile NAME   Profile overlay (e.g., revealui, revealcoin)
  --editor NAME    Editor to link: cursor, zed, vscode, claude, agents, all (default: all)
  --skip NAME      Skip a specific editor (repeatable, comma-separated also works)
  --dry-run        Show what would be done without making changes
  --list           List available profiles and exit
  -h, --help       Show this help

Environment variables:
  REVCON_SKIP_EDITORS         Comma-separated editors to skip by default (e.g., "cursor")
  REVCON_PRIVATE_PROFILES_DIR Additional directory searched for --profile <name>;
                              private profiles take precedence over in-repo ones.

Examples:
  ./link.sh --target ~/revfleet/revealui --profile revealui
  ./link.sh --target ~/revfleet/revealcoin --editor zed
  ./link.sh --dry-run --target ~/revfleet/foo --profile revealui
  ./link.sh --target ~/revfleet/foo --profile revealui --skip cursor
  REVCON_SKIP_EDITORS=cursor ./link.sh --target ~/revfleet/foo --profile revealui
EOF
  exit 0
}

print_profiles() {
  echo "Available profiles:"
  for dir in "$SCRIPT_DIR"/profiles/*/; do
    [ -d "$dir" ] && echo "  $(basename "$dir")"
  done
  if [[ -n "$PRIVATE_PROFILES_DIR" && -d "$PRIVATE_PROFILES_DIR" ]]; then
    for dir in "$PRIVATE_PROFILES_DIR"/*/; do
      [ -d "$dir" ] && echo "  $(basename "$dir") (private)"
    done
  fi
}

list_profiles() {
  print_profiles
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)  TARGET="$2";  shift 2 ;;
    --profile) PROFILE="$2"; shift 2 ;;
    --editor)  EDITOR="$2";  shift 2 ;;
    --skip)    SKIP_EDITORS="${SKIP_EDITORS:+$SKIP_EDITORS,}$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --list)    list_profiles ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

if [[ -z "$TARGET" ]]; then
  echo "Error: --target is required"
  exit 1
fi

TARGET="$(realpath "$TARGET")"

if [[ ! -d "$TARGET" ]]; then
  echo "Error: target directory does not exist: $TARGET"
  exit 1
fi

PROFILE_DIR=""
if [[ -n "$PROFILE" ]]; then
  if [[ -n "$PRIVATE_PROFILES_DIR" && -d "$PRIVATE_PROFILES_DIR/$PROFILE" ]]; then
    PROFILE_DIR="$PRIVATE_PROFILES_DIR/$PROFILE"
  elif [[ -d "$SCRIPT_DIR/profiles/$PROFILE" ]]; then
    PROFILE_DIR="$SCRIPT_DIR/profiles/$PROFILE"
  else
    echo "Error: profile not found: $PROFILE"
    print_profiles
    exit 1
  fi
fi

should_skip_editor() {
  local e="$1"
  [[ -z "$SKIP_EDITORS" ]] && return 1
  [[ ",$SKIP_EDITORS," == *",$e,"* ]]
}

# Map editor names to their dot-directories in the target
declare -A EDITOR_DIRS=(
  [cursor]=".cursor"
  [zed]=".zed"
  [vscode]=".vscode"
  [claude]=".claude"
  [agents]=".agents"
)

LINKED=0
SKIPPED=0

link_file() {
  local src="$1"
  local dst="$2"

  if [[ -L "$dst" ]]; then
    local existing
    existing="$(readlink "$dst")"
    if [[ "$existing" == "$src" ]]; then
      ((SKIPPED++)) || true
      return
    fi
    # Different symlink target — replace
    if $DRY_RUN; then
      echo "  [update] $dst → $src"
    else
      ln -sf "$src" "$dst"
      echo "  [update] $(basename "$dst")"
    fi
    ((LINKED++)) || true
  elif [[ -e "$dst" ]]; then
    echo "  [skip] $(basename "$dst") — real file exists (back up or remove to link)"
    ((SKIPPED++)) || true
  else
    if $DRY_RUN; then
      echo "  [link] $dst → $src"
    else
      ln -s "$src" "$dst"
      echo "  [link] $(basename "$dst")"
    fi
    ((LINKED++)) || true
  fi
}

link_editor() {
  local editor="$1"
  local dot_dir="${EDITOR_DIRS[$editor]}"
  local base_src="$SCRIPT_DIR/base/$editor"
  local profile_src="$PROFILE_DIR/$editor"
  local target_dir="$TARGET/$dot_dir"

  # Check if there are any files to link for this editor
  local has_base=false has_profile=false
  [[ -d "$base_src" ]] && has_base=true
  [[ -n "$PROFILE" && -d "$profile_src" ]] && has_profile=true

  if ! $has_base && ! $has_profile; then
    return
  fi

  echo "[$editor] → $target_dir"

  # Create real directory (not symlink) so editor state stays local
  if ! $DRY_RUN; then
    mkdir -p "$target_dir"
  fi

  # Collect all source files: base first, then profile overlays
  # Use an associative array to deduplicate (profile wins)
  declare -A file_map

  if $has_base; then
    while IFS= read -r -d '' file; do
      local rel="${file#"$base_src/"}"
      file_map["$rel"]="$file"
    done < <(find "$base_src" -type f -print0 | sort -z)
  fi

  if $has_profile; then
    while IFS= read -r -d '' file; do
      local rel="${file#"$profile_src/"}"
      file_map["$rel"]="$file"
    done < <(find "$profile_src" -type f -print0 | sort -z)
  fi

  # Create subdirectories and symlink files
  for rel in $(printf '%s\n' "${!file_map[@]}" | sort); do
    local src="${file_map[$rel]}"
    local dst="$target_dir/$rel"
    local dst_parent
    dst_parent="$(dirname "$dst")"

    if ! $DRY_RUN; then
      mkdir -p "$dst_parent"
    fi

    link_file "$src" "$dst"
  done

  unset file_map
}

ensure_gitignored() {
  local gitignore="$TARGET/.gitignore"
  local entry="$1"

  if [[ ! -f "$gitignore" ]]; then
    if ! $DRY_RUN; then
      echo "$entry" > "$gitignore"
      echo "[gitignore] created with $entry"
    else
      echo "[gitignore] would create with $entry"
    fi
    return
  fi

  if grep -qxF "$entry" "$gitignore" 2>/dev/null; then
    return
  fi

  if $DRY_RUN; then
    echo "[gitignore] would append: $entry"
  else
    # Add under an editor-configs section if it doesn't exist
    if ! grep -q '# editor-configs (symlinked)' "$gitignore" 2>/dev/null; then
      printf '\n# editor-configs (symlinked)\n' >> "$gitignore"
    fi
    echo "$entry" >> "$gitignore"
    echo "[gitignore] appended: $entry"
  fi
}

# Run
echo "Linking editor configs → $TARGET"
[[ -n "$PROFILE" ]] && echo "Profile: $PROFILE"
$DRY_RUN && echo "(dry run)"
echo ""

if [[ "$EDITOR" == "all" ]]; then
  for e in cursor zed vscode claude agents; do
    if should_skip_editor "$e"; then
      echo "[$e] skipped (REVCON_SKIP_EDITORS / --skip)"
      continue
    fi
    link_editor "$e"
  done
else
  if should_skip_editor "$EDITOR"; then
    echo "[$EDITOR] skipped (REVCON_SKIP_EDITORS / --skip)"
  else
    link_editor "$EDITOR"
  fi
fi

echo ""

# Gitignore entries
if [[ "$EDITOR" == "all" ]]; then
  for e in cursor zed vscode claude agents; do
    should_skip_editor "$e" && continue
    ensure_gitignored "${EDITOR_DIRS[$e]}/"
  done
else
  if ! should_skip_editor "$EDITOR"; then
    ensure_gitignored "${EDITOR_DIRS[$EDITOR]}/"
  fi
fi

echo ""
echo "Done: $LINKED linked, $SKIPPED unchanged"
