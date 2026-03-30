#!/usr/bin/env bash
# status.sh — Report which editor-config profiles are linked where.
#
# Usage:
#   ./status.sh                                        # scan ~/projects/*/
#   ./status.sh --target ~/projects/RevealUI           # check one target
#   ./status.sh --editor zed                           # filter to zed only
#   ./status.sh --json                                 # machine-readable output
#   ./status.sh --target ~/projects/RevealUI --json    # combined

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET=""
EDITOR="all"
JSON=false

usage() {
  cat <<'EOF'
Usage: status.sh [OPTIONS]

Options:
  --target DIR     Check a specific project directory (default: scan ~/projects/*/)
  --editor NAME    Filter to editor: cursor, zed, vscode (default: all)
  --json           Machine-readable JSON output
  -h, --help       Show this help

Examples:
  ./status.sh
  ./status.sh --target ~/projects/RevealUI
  ./status.sh --editor zed --json
  ./status.sh --target ~/projects/RevealUI --editor cursor --json
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) TARGET="$2";  shift 2 ;;
    --editor) EDITOR="$2";  shift 2 ;;
    --json)   JSON=true;    shift ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

# Map editor names to their dot-directories in the target
declare -A EDITOR_DIRS=(
  [cursor]=".cursor"
  [zed]=".zed"
  [vscode]=".vscode"
)

# Build list of editors to check
EDITORS=()
if [[ "$EDITOR" == "all" ]]; then
  EDITORS=(cursor zed vscode)
else
  if [[ -z "${EDITOR_DIRS[$EDITOR]+x}" ]]; then
    echo "Error: unknown editor: $EDITOR (expected cursor, zed, or vscode)"
    exit 1
  fi
  EDITORS=("$EDITOR")
fi

# --- Discovery ---

# Scan ~/projects/*/ for directories with symlinks pointing back to this repo.
discover_targets() {
  for dir in "$HOME"/projects/*/; do
    [[ -d "$dir" ]] || continue
    local dir_real
    dir_real="$(realpath "$dir")"
    # Skip the editor-configs repo itself
    [[ "$dir_real" == "$SCRIPT_DIR" ]] && continue
    # Check if any editor dot-dir exists with symlinks into our repo
    for e in "${EDITORS[@]}"; do
      local dot_dir="${EDITOR_DIRS[$e]}"
      local check_dir="$dir$dot_dir"
      if [[ -d "$check_dir" ]]; then
        local found=false
        while IFS= read -r -d '' link; do
          local dest
          dest="$(readlink "$link" 2>/dev/null || true)"
          if [[ "$dest" == "$SCRIPT_DIR"* ]]; then
            found=true
            break
          fi
        done < <(find "$check_dir" -type l -print0 2>/dev/null)
        if $found; then
          echo "$dir_real"
          break
        fi
      fi
    done
  done
}

TARGETS=()
if [[ -n "$TARGET" ]]; then
  TARGET="$(realpath "$TARGET")"
  if [[ ! -d "$TARGET" ]]; then
    echo "Error: target directory does not exist: $TARGET"
    exit 1
  fi
  TARGETS=("$TARGET")
else
  while IFS= read -r t; do
    TARGETS+=("$t")
  done < <(discover_targets | sort -u)
fi

if [[ ${#TARGETS[@]} -eq 0 ]]; then
  if $JSON; then
    echo '{"targets":[]}'
  else
    echo "No linked targets found."
  fi
  exit 0
fi

# --- Helpers ---

# Derive profile name from a symlink target path.
# Returns the profile name if the source is under profiles/<name>/,
# or empty string if from base/.
derive_profile() {
  local src="$1"
  local rel="${src#"$SCRIPT_DIR/"}"
  if [[ "$rel" == profiles/* ]]; then
    local after="${rel#profiles/}"
    echo "${after%%/*}"
  fi
}

# Derive the display source path (relative to SCRIPT_DIR)
derive_source() {
  local src="$1"
  echo "${src#"$SCRIPT_DIR/"}"
}

# --- Collect data ---

JSON_TARGETS=()

print_human_header() {
  echo "Editor Configs Status"
  printf '\xe2\x95\x90%.0s' {1..23}
  echo ""
  echo ""
}

process_target() {
  local target="$1"
  local json_editors=""

  if ! $JSON; then
    echo "Target: $target"
  fi

  for e in "${EDITORS[@]}"; do
    local dot_dir="${EDITOR_DIRS[$e]}"
    local target_dir="$target/$dot_dir"

    local linked=0
    local broken=0
    local profile=""
    local files_human=""
    local files_json=""

    if [[ ! -d "$target_dir" ]]; then
      if ! $JSON; then
        echo "  [$e] not linked"
      else
        local ej
        ej=$(printf '"%s":{"linked":0,"broken":0,"profile":null,"files":[]}' "$e")
        if [[ -n "$json_editors" ]]; then
          json_editors="$json_editors,$ej"
        else
          json_editors="$ej"
        fi
      fi
      continue
    fi

    # Find all symlinks (including broken ones) pointing into our repo
    local found_any=false
    while IFS= read -r -d '' link; do
      local dest
      dest="$(readlink "$link" 2>/dev/null || true)"
      # Only consider symlinks pointing into our repo
      [[ "$dest" == "$SCRIPT_DIR"* ]] || continue
      found_any=true

      local rel_name
      rel_name="${link#"$target_dir/"}"
      local source_rel
      source_rel="$(derive_source "$dest")"
      local file_profile
      file_profile="$(derive_profile "$dest")"

      # Track profile (use the first profile found; they should all match)
      if [[ -n "$file_profile" && -z "$profile" ]]; then
        profile="$file_profile"
      fi

      # Check if symlink target exists (broken = dangling)
      local ok=true
      if [[ ! -e "$link" ]]; then
        ok=false
        ((broken++)) || true
      fi
      ((linked++)) || true

      if ! $JSON; then
        if $ok; then
          files_human+=$'    \xe2\x9c\x93 '"$rel_name"$' \xe2\x86\x92 '"$source_rel"$'\n'
        else
          files_human+=$'    \xe2\x9c\x97 '"$rel_name"$' (broken symlink)\n'
        fi
      else
        local fe
        if $ok; then
          fe=$(printf '{"name":"%s","source":"%s","ok":true}' "$rel_name" "$source_rel")
        else
          fe=$(printf '{"name":"%s","source":"%s","ok":false}' "$rel_name" "$source_rel")
        fi
        if [[ -n "$files_json" ]]; then
          files_json="$files_json,$fe"
        else
          files_json="$fe"
        fi
      fi
    done < <(find "$target_dir" -type l -print0 2>/dev/null | sort -z)

    if ! $found_any; then
      if ! $JSON; then
        echo "  [$e] not linked"
      else
        local ej
        ej=$(printf '"%s":{"linked":0,"broken":0,"profile":null,"files":[]}' "$e")
        if [[ -n "$json_editors" ]]; then
          json_editors="$json_editors,$ej"
        else
          json_editors="$ej"
        fi
      fi
      continue
    fi

    if ! $JSON; then
      local profile_label
      if [[ -n "$profile" ]]; then
        profile_label="profile: $profile"
      else
        profile_label="base only"
      fi
      echo "  [$e] $linked linked ($profile_label)"
      printf '%b' "$files_human"
    else
      local pj
      if [[ -n "$profile" ]]; then
        pj="\"$profile\""
      else
        pj="null"
      fi
      local ej
      ej=$(printf '"%s":{"linked":%d,"broken":%d,"profile":%s,"files":[%s]}' \
        "$e" "$linked" "$broken" "$pj" "$files_json")
      if [[ -n "$json_editors" ]]; then
        json_editors="$json_editors,$ej"
      else
        json_editors="$ej"
      fi
    fi
  done

  if $JSON; then
    local tj
    tj=$(printf '{"path":"%s","editors":{%s}}' "$target" "$json_editors")
    JSON_TARGETS+=("$tj")
  else
    echo ""
  fi
}

# --- Main ---

if ! $JSON; then
  print_human_header
fi

for t in "${TARGETS[@]}"; do
  process_target "$t"
done

if $JSON; then
  joined=""
  for entry in "${JSON_TARGETS[@]}"; do
    if [[ -n "$joined" ]]; then
      joined="$joined,$entry"
    else
      joined="$entry"
    fi
  done
  printf '{"targets":[%s]}\n' "$joined"
fi
