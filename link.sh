#!/usr/bin/env bash
# link.sh — Symlink editor configs into a target project.
#
# Usage:
#   ./link.sh --target ~/revfleet/revealui --profile revealui
#   ./link.sh --target ~/revfleet/revealui --profile revfleet --profile revealui
#   ./link.sh --target ~/revfleet/revforge                    # base only
#   ./link.sh --target ~/revfleet/revealui --editor zed         # zed only
#   ./link.sh --list                                            # show available profiles
#
# Creates real directories (.zed/, .cursor/, .claude/, .agents/) in the target,
# then symlinks individual config files from base/ and optionally one or more
# profile overlays. --profile is repeatable; profiles are applied in the order
# given, and later profiles override earlier ones on filename collisions
# (base → first profile → second profile → ...).
# Adds symlinked dirs to the target's .gitignore.
#
# With --mode copy, files are materialized as real copies instead of symlinks,
# a deterministic <dot_dir>/.revcon-manifest.json (per-file source + sha256)
# is written, and no .gitignore entry is added: the target repo is expected to
# TRACK the copies and gate drift with a lockstep check against the manifest.
# Re-running with unchanged profiles is a no-op (idempotent apply).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET=""
PROFILES=()
EDITOR="all"
MODE="symlink"
DRY_RUN=false
SKIP_EDITORS="${REVCON_SKIP_EDITORS:-}"
PRIVATE_PROFILES_DIR="${REVCON_PRIVATE_PROFILES_DIR:-}"

usage() {
  cat <<'EOF'
Usage: link.sh [OPTIONS]

Options:
  --target DIR     Project directory to link into (required)
  --profile NAME   Profile overlay (repeatable; later wins on collision)
                   Examples: revfleet, revealui, revforge
  --editor NAME    Editor to link: cursor, zed, vscode, claude, agents, all (default: all)
  --mode NAME      Distribution mode: symlink (default) or copy. Copy mode
                   materializes real files so the target repo can git-track
                   them, writes <dot_dir>/.revcon-manifest.json (per-file
                   source + sha256), and does NOT gitignore the dot-dir.
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
  ./link.sh --target ~/revfleet/revealui --profile revfleet --profile revealui
  ./link.sh --target ~/revfleet/revforge --profile revfleet
  ./link.sh --target ~/revfleet/foo --editor zed
  ./link.sh --dry-run --target ~/revfleet/foo --profile revfleet
  REVCON_SKIP_EDITORS=cursor ./link.sh --target ~/revfleet/foo --profile revfleet
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
    --profile) PROFILES+=("$2"); shift 2 ;;
    --editor)  EDITOR="$2";  shift 2 ;;
    --mode)    MODE="$2";    shift 2 ;;
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

if [[ "$MODE" != "symlink" && "$MODE" != "copy" ]]; then
  echo "Error: --mode must be 'symlink' or 'copy' (got: $MODE)"
  exit 1
fi

TARGET="$(realpath "$TARGET")"

if [[ ! -d "$TARGET" ]]; then
  echo "Error: target directory does not exist: $TARGET"
  exit 1
fi

# Resolve each profile name to its directory (private dir wins over in-repo).
# Order is preserved so later profiles override earlier ones on file collisions.
PROFILE_DIRS=()
for profile in "${PROFILES[@]+"${PROFILES[@]}"}"; do
  if [[ -n "$PRIVATE_PROFILES_DIR" && -d "$PRIVATE_PROFILES_DIR/$profile" ]]; then
    PROFILE_DIRS+=("$PRIVATE_PROFILES_DIR/$profile")
  elif [[ -d "$SCRIPT_DIR/profiles/$profile" ]]; then
    PROFILE_DIRS+=("$SCRIPT_DIR/profiles/$profile")
  else
    echo "Error: profile not found: $profile"
    print_profiles
    exit 1
  fi
done

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
COPIED=0

# Manifest source path for an absolute source file: relative to the revcon
# repo, or "private:<rel>" when it comes from the private profiles dir.
manifest_source() {
  local src="$1"
  if [[ -n "$PRIVATE_PROFILES_DIR" && "$src" == "$PRIVATE_PROFILES_DIR/"* ]]; then
    echo "private:${src#"$PRIVATE_PROFILES_DIR/"}"
  else
    echo "${src#"$SCRIPT_DIR/"}"
  fi
}

copy_file() {
  local src="$1"
  local dst="$2"

  if [[ -L "$dst" ]]; then
    # Symlink (revcon-managed or otherwise) becomes a real file
    if $DRY_RUN; then
      echo "  [materialize] $dst (symlink -> copy of $src)"
    else
      rm "$dst"
      cp "$src" "$dst"
      echo "  [materialize] $(basename "$dst")"
    fi
    ((COPIED++)) || true
  elif [[ -e "$dst" ]]; then
    if cmp -s "$src" "$dst"; then
      ((SKIPPED++)) || true
    else
      # Profiles are the source of truth; converge the copy. Local edits are
      # caught by the target repo's lockstep gate, not preserved here.
      if $DRY_RUN; then
        echo "  [update] $dst (differs from $src)"
      else
        cp "$src" "$dst"
        echo "  [update] $(basename "$dst")"
      fi
      ((COPIED++)) || true
    fi
  else
    if $DRY_RUN; then
      echo "  [copy] $dst <- $src"
    else
      cp "$src" "$dst"
      echo "  [copy] $(basename "$dst")"
    fi
    ((COPIED++)) || true
  fi
}

# Write a deterministic manifest for a materialized editor dir: sorted keys,
# two-space indent, no timestamps, so an unchanged re-apply produces no diff.
write_manifest() {
  local target_dir="$1"
  local editor="$2"
  local -n fmap="$3"
  local manifest="$target_dir/.revcon-manifest.json"

  local profiles_json=""
  local p
  for p in "${PROFILES[@]+"${PROFILES[@]}"}"; do
    profiles_json+="${profiles_json:+, }\"$p\""
  done

  {
    printf '{\n'
    printf '  "mode": "copy",\n'
    printf '  "editor": "%s",\n' "$editor"
    printf '  "profiles": [%s],\n' "$profiles_json"
    printf '  "files": {\n'
    local first=true
    local rel
    for rel in $(printf '%s\n' "${!fmap[@]}" | sort); do
      local src="${fmap[$rel]}"
      local hash
      hash="$(sha256sum "$src" | cut -d' ' -f1)"
      $first || printf ',\n'
      first=false
      printf '    "%s": {\n      "source": "%s",\n      "sha256": "%s"\n    }' \
        "$rel" "$(manifest_source "$src")" "$hash"
    done
    printf '\n  }\n}\n'
  } > "$manifest"
  echo "  [manifest] ${manifest#"$TARGET/"}"
}

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
  local target_dir="$TARGET/$dot_dir"

  # Check if there are any files to link for this editor
  local has_base=false
  local has_any_profile=false
  [[ -d "$base_src" ]] && has_base=true
  for pdir in "${PROFILE_DIRS[@]+"${PROFILE_DIRS[@]}"}"; do
    if [[ -d "$pdir/$editor" ]]; then
      has_any_profile=true
      break
    fi
  done

  if ! $has_base && ! $has_any_profile; then
    return
  fi

  echo "[$editor] → $target_dir"

  # Create real directory (not symlink) so editor state stays local
  if ! $DRY_RUN; then
    mkdir -p "$target_dir"
  fi

  # Collect all source files: base first, then each profile in order.
  # Use an associative array to deduplicate (later overlay wins).
  declare -A file_map

  if $has_base; then
    while IFS= read -r -d '' file; do
      local rel="${file#"$base_src/"}"
      file_map["$rel"]="$file"
    done < <(find "$base_src" -type f -print0 | sort -z)
  fi

  for pdir in "${PROFILE_DIRS[@]+"${PROFILE_DIRS[@]}"}"; do
    local profile_src="$pdir/$editor"
    [[ -d "$profile_src" ]] || continue
    while IFS= read -r -d '' file; do
      local rel="${file#"$profile_src/"}"
      file_map["$rel"]="$file"
    done < <(find "$profile_src" -type f -print0 | sort -z)
  done

  # Create subdirectories and symlink files
  for rel in $(printf '%s\n' "${!file_map[@]}" | sort); do
    local src="${file_map[$rel]}"
    local dst="$target_dir/$rel"
    local dst_parent
    dst_parent="$(dirname "$dst")"

    if ! $DRY_RUN; then
      mkdir -p "$dst_parent"
    fi

    if [[ "$MODE" == "copy" ]]; then
      copy_file "$src" "$dst"
    else
      link_file "$src" "$dst"
    fi
  done

  if [[ "$MODE" == "copy" ]] && ! $DRY_RUN; then
    write_manifest "$target_dir" "$editor" file_map
  fi

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
if [[ ${#PROFILES[@]} -gt 0 ]]; then
  echo "Profiles: ${PROFILES[*]}  (later overrides earlier on collision)"
fi
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

# Gitignore entries (symlink mode only). Copy mode expects the target repo to
# TRACK the materialized files; warn if an ignore rule would swallow them.
warn_if_ignored() {
  local dot_dir="$1"
  local gitignore="$TARGET/.gitignore"
  [[ -f "$gitignore" ]] || return 0
  # A bare dir ignore ("<dot_dir>/" or "<dot_dir>") swallows everything and
  # cannot be negated below it. The children-glob form ("<dot_dir>/*") is the
  # CORRECT copy-mode setup (it supports !<dot_dir>/rules/ negations), so it
  # does not warn.
  if grep -qxF "$dot_dir/" "$gitignore" || grep -qxF "$dot_dir" "$gitignore"; then
    echo "[warn] $gitignore ignores $dot_dir/ at the directory level - switch to '$dot_dir/*' plus negations so the materialized paths can be tracked"
  fi
}

if [[ "$EDITOR" == "all" ]]; then
  for e in cursor zed vscode claude agents; do
    should_skip_editor "$e" && continue
    if [[ "$MODE" == "copy" ]]; then
      warn_if_ignored "${EDITOR_DIRS[$e]}"
    else
      ensure_gitignored "${EDITOR_DIRS[$e]}/"
    fi
  done
else
  if ! should_skip_editor "$EDITOR"; then
    if [[ "$MODE" == "copy" ]]; then
      warn_if_ignored "${EDITOR_DIRS[$EDITOR]}"
    else
      ensure_gitignored "${EDITOR_DIRS[$EDITOR]}/"
    fi
  fi
fi

echo ""
if [[ "$MODE" == "copy" ]]; then
  echo "Done: $COPIED copied, $SKIPPED unchanged"
else
  echo "Done: $LINKED linked, $SKIPPED unchanged"
fi
