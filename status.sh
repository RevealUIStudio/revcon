#!/usr/bin/env bash
# status.sh — Report which editor-config profiles are linked where.
#
# Usage:
#   ./status.sh                                        # scan ~/revfleet/*/
#   ./status.sh --target ~/revfleet/revealui           # check one target
#   ./status.sh --editor zed                           # filter to zed only
#   ./status.sh --json                                 # machine-readable output
#   ./status.sh --target ~/revfleet/revealui --json    # combined

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET=""
EDITOR="all"
JSON=false
SKIP_EDITORS="${REVCON_SKIP_EDITORS:-}"
PRIVATE_PROFILES_DIR="${REVCON_PRIVATE_PROFILES_DIR:-}"

usage() {
  cat <<'EOF'
Usage: status.sh [OPTIONS]

Options:
  --target DIR     Check a specific project directory (default: scan ~/revfleet/*/)
  --editor NAME    Filter to editor: cursor, zed, vscode, claude, agents (default: all)
  --skip NAME      Skip a specific editor (repeatable, comma-separated also works)
  --json           Machine-readable JSON output
  -h, --help       Show this help

Environment variables:
  REVCON_SKIP_EDITORS         Comma-separated editors to skip by default
  REVCON_PRIVATE_PROFILES_DIR Treat symlinks pointing into this dir as linked too

Examples:
  ./status.sh
  ./status.sh --target ~/revfleet/revealui
  ./status.sh --editor zed --json
  ./status.sh --target ~/revfleet/revealui --editor cursor --json
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) TARGET="$2";  shift 2 ;;
    --editor) EDITOR="$2";  shift 2 ;;
    --skip)   SKIP_EDITORS="${SKIP_EDITORS:+$SKIP_EDITORS,}$2"; shift 2 ;;
    --json)   JSON=true;    shift ;;
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

# Map editor names to their dot-directories in the target
declare -A EDITOR_DIRS=(
  [cursor]=".cursor"
  [zed]=".zed"
  [vscode]=".vscode"
  [claude]=".claude"
  [agents]=".agents"
)

# Build list of editors to check
EDITORS=()
if [[ "$EDITOR" == "all" ]]; then
  for e in cursor zed vscode claude agents; do
    should_skip_editor "$e" && continue
    EDITORS+=("$e")
  done
else
  if [[ -z "${EDITOR_DIRS[$EDITOR]+x}" ]]; then
    echo "Error: unknown editor: $EDITOR (expected cursor, zed, vscode, claude, or agents)"
    exit 1
  fi
  if should_skip_editor "$EDITOR"; then
    echo "Error: editor $EDITOR is in REVCON_SKIP_EDITORS / --skip"
    exit 1
  fi
  EDITORS=("$EDITOR")
fi

# --- Discovery ---

# Scan ~/revfleet/*/ for directories with symlinks pointing back to this repo.
discover_targets() {
  for dir in "$HOME"/revfleet/*/; do
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
        # Materialized (copy-mode) targets carry a manifest, no symlinks
        if [[ -f "$check_dir/.revcon-manifest.json" ]]; then
          echo "$dir_real"
          break
        fi
        local found=false
        while IFS= read -r -d '' link; do
          local dest
          dest="$(readlink "$link" 2>/dev/null || true)"
          if is_revcon_link "$dest"; then
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
# Returns the profile name if the source is under profiles/<name>/ (in-repo)
# or under $PRIVATE_PROFILES_DIR/<name>/ (private). Empty string if from base/.
derive_profile() {
  local src="$1"
  if [[ -n "$PRIVATE_PROFILES_DIR" && "$src" == "$PRIVATE_PROFILES_DIR/"* ]]; then
    local after="${src#"$PRIVATE_PROFILES_DIR/"}"
    echo "${after%%/*} (private)"
    return
  fi
  local rel="${src#"$SCRIPT_DIR/"}"
  if [[ "$rel" == profiles/* ]]; then
    local after="${rel#profiles/}"
    echo "${after%%/*}"
  fi
}

# Derive the display source path. In-repo paths are shown relative to SCRIPT_DIR;
# private-dir paths are tagged with a "private:" prefix.
derive_source() {
  local src="$1"
  if [[ -n "$PRIVATE_PROFILES_DIR" && "$src" == "$PRIVATE_PROFILES_DIR/"* ]]; then
    echo "private:${src#"$PRIVATE_PROFILES_DIR/"}"
  else
    echo "${src#"$SCRIPT_DIR/"}"
  fi
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

    # Copy-mode (materialized) dirs carry a manifest instead of symlinks:
    # verify each copy against the manifest hash (local edits) AND against the
    # current profile source (stale copies).
    local manifest="$target_dir/.revcon-manifest.json"
    if [[ -f "$manifest" ]]; then
      if command -v jq >/dev/null 2>&1; then
        local m_total=0 m_ok=0 m_bad=0
        local m_profiles=""
        m_profiles="$(jq -r '.profiles | join(", ")' "$manifest" 2>/dev/null || true)"
        while IFS=$'\t' read -r rel src_rel want_hash; do
          [[ -n "$rel" ]] || continue
          ((m_total++)) || true
          local fpath="$target_dir/$rel"
          local state="ok"
          if [[ ! -f "$fpath" ]]; then
            state="missing"
          else
            local have_hash
            have_hash="$(sha256sum "$fpath" | cut -d' ' -f1)"
            if [[ "$have_hash" != "$want_hash" ]]; then
              state="modified"
            else
              local src_abs
              if [[ "$src_rel" == private:* ]]; then
                src_abs="$PRIVATE_PROFILES_DIR/${src_rel#private:}"
              else
                src_abs="$SCRIPT_DIR/$src_rel"
              fi
              if [[ ! -f "$src_abs" ]]; then
                state="orphaned"
              else
                local src_hash
                src_hash="$(sha256sum "$src_abs" | cut -d' ' -f1)"
                [[ "$src_hash" == "$want_hash" ]] || state="stale"
              fi
            fi
          fi
          if [[ "$state" == "ok" ]]; then
            ((m_ok++)) || true
            $JSON || files_human+=$'    \xe2\x9c\x93 '"$rel"$'\n'
          else
            ((m_bad++)) || true
            $JSON || files_human+=$'    \xe2\x9c\x97 '"$rel"$' ('"$state"$')\n'
          fi
          if $JSON; then
            local fe
            fe=$(printf '{"name":"%s","source":"%s","state":"%s"}' "$rel" "$src_rel" "$state")
            if [[ -n "$files_json" ]]; then files_json="$files_json,$fe"; else files_json="$fe"; fi
          fi
        done < <(jq -r '.files | to_entries[] | [.key, .value.source, .value.sha256] | @tsv' "$manifest" 2>/dev/null)
        if ! $JSON; then
          echo "  [$e] $m_total materialized, $m_ok ok, $m_bad drifted (mode: copy, profiles: $m_profiles)"
          printf '%b' "$files_human"
        else
          local ej
          ej=$(printf '"%s":{"mode":"copy","materialized":%d,"ok":%d,"drifted":%d,"profiles":"%s","files":[%s]}' \
            "$e" "$m_total" "$m_ok" "$m_bad" "$m_profiles" "$files_json")
          if [[ -n "$json_editors" ]]; then json_editors="$json_editors,$ej"; else json_editors="$ej"; fi
        fi
      else
        if ! $JSON; then
          echo "  [$e] materialized (mode: copy) - jq not found, cannot verify"
        else
          local ej
          ej=$(printf '"%s":{"mode":"copy","materialized":null,"error":"jq not found"}' "$e")
          if [[ -n "$json_editors" ]]; then json_editors="$json_editors,$ej"; else json_editors="$ej"; fi
        fi
      fi
      continue
    fi

    # Find all symlinks (including broken ones) pointing into our repo
    local found_any=false
    while IFS= read -r -d '' link; do
      local dest
      dest="$(readlink "$link" 2>/dev/null || true)"
      # Only consider symlinks pointing into our repo or the private profiles dir
      is_revcon_link "$dest" || continue
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
