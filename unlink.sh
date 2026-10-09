#!/usr/bin/env bash
# unlink.sh — Remove managed editor configs from a target project.
#
# Usage:
#   ./unlink.sh --target ~/revealfleet/revealui
#   ./unlink.sh --target ~/revealfleet/revealui --editor zed
#
# Removes symlinks that point back into this editor-configs repo, and
# copy-mode files whose hash still matches the manifest. Real files (local
# overrides, editor state) are left untouched. A manifest path that escapes
# the editor directory fails closed before any removal. Empty directories
# are cleaned up. Gitignore entries are NOT removed (harmless to keep,
# avoids accidental commits if re-linking later).

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
  --editor NAME    Editor to unlink: revealui, cursor, zed, vscode, claude, grok, agents, all (default: all)
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
  # Match the repo dir itself or paths strictly beneath it. A bare prefix
  # match ("$SCRIPT_DIR"*) would also match siblings like "<repo>-backups/...",
  # which here means deleting (unlink.sh) or mis-reporting (status.sh) symlinks
  # that revcon does not own.
  [[ "$dest" == "$SCRIPT_DIR" || "$dest" == "$SCRIPT_DIR"/* ]] && return 0
  [[ -n "$PRIVATE_PROFILES_DIR" && ( "$dest" == "$PRIVATE_PROFILES_DIR" || "$dest" == "$PRIVATE_PROFILES_DIR"/* ) ]] && return 0
  return 1
}

if [[ -z "$TARGET" ]]; then
  echo "Error: --target is required"
  exit 1
fi

TARGET="$(realpath "$TARGET")"

declare -A EDITOR_DIRS=(
  [revealui]=".revealui"
  [cursor]=".cursor"
  [zed]=".zed"
  [vscode]=".vscode"
  [claude]=".claude"
  [grok]=".grok"
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

  if [[ -L "$target_dir" ]]; then
    echo "Error: unsafe editor directory; preserving files" >&2
    exit 1
  fi

  # Admit every manifest path before deleting anything. A key such as
  # "../../secret" or a symlink inside the editor directory must not make
  # rm follow a path outside this dot-dir.
  local manifest="$target_dir/.revcon-manifest.json"
  if [[ "$editor" == "revealui" ]]; then
    if [[ -e "$manifest" ]]; then
      if [[ -L "$manifest" ]] || ! command -v jq >/dev/null || ! jq -se '
        length == 1 and .[0].mode == "copy" and .[0].editor == "revealui" and
        (.[0].files | type == "object") and
        all(.[0].files | to_entries[];
          (.key | startswith("content/rules/") or startswith("content/agents/") or
            startswith("content/skills/") or startswith("content/commands/")) and
          (.key | split("/") | all(.[]; length > 0 and . != "." and . != "..")) and
          (.key | test("[[:cntrl:]]") | not) and
          (.value.sha256 | type == "string" and test("^[0-9a-f]{64}$")))
      ' "$manifest" >/dev/null 2>&1; then
        echo "Error: invalid native policy manifest; preserving files" >&2; exit 1
      fi
      while IFS= read -r rel; do
        local native_dst="$target_dir/$rel" resolved
        resolved="$(realpath -m -- "$native_dst")"
        [[ "$resolved" == "$target_dir/"* ]] || { echo "Error: unsafe native policy path; preserving files" >&2; exit 1; }
      done < <(jq -r '.files | keys[]' "$manifest")
    fi
  elif [[ -L "$manifest" ]]; then
    echo "Error: unsafe copy manifest; preserving files" >&2
    exit 1
  elif [[ -f "$manifest" ]] && command -v jq >/dev/null 2>&1; then
    if ! jq -se '
      length == 1 and (.[0] | type == "object") and .[0].mode == "copy" and
      (.[0].files | type == "object") and
      all(.[0].files | to_entries[];
        (.key | type == "string") and
        (.key | startswith("/") | not) and
        (.key | test("[[:cntrl:]]") | not) and
        (.key | split("/") | all(.[]; length > 0 and . != "." and . != "..")) and
        (.value | type == "object") and
        (.value.sha256 | type == "string" and test("^[0-9a-f]{64}$")))
    ' "$manifest" >/dev/null 2>&1; then
      echo "Error: invalid copy manifest; preserving files" >&2
      exit 1
    fi
    while IFS= read -r rel; do
      local vendor_dst="$target_dir/$rel" resolved
      resolved="$(realpath -m -- "$vendor_dst")"
      [[ "$resolved" == "$target_dir/"* ]] || { echo "Error: unsafe copy path; preserving files" >&2; exit 1; }
    done < <(jq -r '.files | keys[]' "$manifest")
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

  # Copy-mode (materialized) dirs: remove manifest-listed copies whose hash
  # still matches the manifest; keep locally-modified files and warn.
  # Path admission above already rejected escapes; this loop only removes
  # keys that stayed inside the editor directory.
  if [[ -f "$manifest" ]]; then
    if command -v jq >/dev/null 2>&1; then
      local kept=0
      local -a removed_entries=()
      while IFS=$'\t' read -r rel want_hash source; do
        [[ -n "$rel" ]] || continue
        if [[ "$editor" == "claude" && "$source" == harnesses:* ]]; then
          echo "  [keep] $rel - harness owned"
          ((kept++)) || true
          continue
        fi
        local fpath="$target_dir/$rel"
        [[ -f "$fpath" ]] || continue
        local have_hash
        have_hash="$(sha256sum "$fpath" | cut -d' ' -f1)"
        if [[ "$have_hash" == "$want_hash" ]]; then
          if $DRY_RUN; then
            echo "  [remove] $fpath (materialized copy)"
          else
            rm "$fpath"
            removed_entries+=("$rel")
            echo "  [remove] $rel"
          fi
          ((REMOVED++)) || true
        else
          echo "  [keep] $rel - locally modified, not removing"
          ((kept++)) || true
        fi
      done < <(jq -r '.files | to_entries[] | [.key, .value.sha256, .value.source] | @tsv' "$manifest" 2>/dev/null)
      if [[ $kept -eq 0 ]]; then
        if $DRY_RUN; then
          echo "  [remove] $manifest"
        else
          rm "$manifest"
          echo "  [remove] .revcon-manifest.json"
        fi
        ((REMOVED++)) || true
      else
        if ! $DRY_RUN && [[ ${#removed_entries[@]} -gt 0 ]]; then
          local ledger_tmp removed_json
          ledger_tmp="$(mktemp "$target_dir/.revcon-manifest.XXXXXX")"
          removed_json="$(printf '%s\n' "${removed_entries[@]}" | jq -R . | jq -s .)"
          jq --argjson removed "$removed_json" '.files |= delpaths($removed | map([.]))' "$manifest" > "$ledger_tmp"
          mv "$ledger_tmp" "$manifest"
        fi
        echo "  [keep] .revcon-manifest.json - $kept owned or modified file(s) remain"
      fi
    else
      echo "  [skip] $manifest present but jq not found - cannot verify copies, leaving in place"
    fi
  fi

  # Projection marker is not a manifest entry. Remove it only when it is ours.
  local generated_from="$target_dir/.generated-from"
  if [[ -f "$generated_from" && ! -L "$generated_from" ]] && grep -q '^generated from \.revealui' "$generated_from"; then
    if $DRY_RUN; then
      echo "  [remove] $generated_from"
    else
      rm "$generated_from"
      echo "  [remove] .generated-from"
    fi
    ((REMOVED++)) || true
  fi

  # Clean up empty subdirectories (bottom-up)
  if ! $DRY_RUN; then
    find "$target_dir" -type d -empty -delete 2>/dev/null || true
  fi
}

echo "Unlinking editor configs from $TARGET"
$DRY_RUN && echo "(dry run)"
echo ""

if [[ "$EDITOR" == "all" ]]; then
  for e in revealui cursor zed vscode claude grok agents; do
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
echo "Done: $REMOVED managed entries removed"
echo "Note: .gitignore entries preserved (safe to keep)"
