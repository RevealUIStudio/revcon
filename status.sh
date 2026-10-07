#!/usr/bin/env bash
# status.sh — Report which editor-config profiles are linked where.
#
# Usage:
#   ./status.sh                                        # scan sibling projects
#   ./status.sh --target ~/revealfleet/revealui         # check one target
#   ./status.sh --editor zed                           # filter to zed only
#   ./status.sh --json                                 # machine-readable output
#   ./status.sh --target ~/revealfleet/revealui --json  # combined
#   ./status.sh --target DIR --editor claude --verify  # exit 1 on copy-mode drift (GAP-372)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FLEET_DIR="$(dirname "$SCRIPT_DIR")"
TARGET=""
EDITOR="all"
JSON=false
VERIFY=false
SKIP_EDITORS="${REVCON_SKIP_EDITORS:-}"
PRIVATE_PROFILES_DIR="${REVCON_PRIVATE_PROFILES_DIR:-}"
# Accumulator for --verify (copy-mode drifted/missing counts across targets)
VERIFY_BAD=0

usage() {
  cat <<'EOF'
Usage: status.sh [OPTIONS]

Options:
  --target DIR     Check a specific project directory (default: scan sibling projects)
  --editor NAME    Filter to editor: revealui, cursor, zed, vscode, claude, grok, agents (default: all)
  --skip NAME      Skip a specific editor (repeatable, comma-separated also works)
  --json           Machine-readable JSON output
  --verify         Exit 1 if any copy-mode materialization has drift (GAP-372).
                   Prefer scripts/verify-copy-lockstep.sh in consumer CI (self-
                   consistency, no profile checkout). This flag also flags
                   profile-source staleness when this revcon tree is present.
  -h, --help       Show this help

Environment variables:
  REVCON_SKIP_EDITORS         Comma-separated editors to skip by default
  REVCON_PRIVATE_PROFILES_DIR Treat symlinks pointing into this dir as linked too

Examples:
  ./status.sh
  ./status.sh --target ~/revealfleet/revealui
  ./status.sh --editor zed --json
  ./status.sh --target ~/revealfleet/revealui --editor cursor --json
  ./status.sh --target ~/revealfleet/revdev --editor claude --verify
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) TARGET="$2";  shift 2 ;;
    --editor) EDITOR="$2";  shift 2 ;;
    --skip)   SKIP_EDITORS="${SKIP_EDITORS:+$SKIP_EDITORS,}$2"; shift 2 ;;
    --json)   JSON=true;    shift ;;
    --verify) VERIFY=true;  shift ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

should_skip_editor() {
  local e="$1"
  [[ -z "$SKIP_EDITORS" ]] && return 1
  [[ ",$SKIP_EDITORS," == *",$e,"* ]]
}

json_quote() {
  local input="$1" output='"' char code hex i
  local LC_ALL=C
  for ((i=0; i<${#input}; i++)); do
    char="${input:i:1}"
    case "$char" in
      '"') output+='\"' ;;
      '\') output+='\\' ;;
      *)
        printf -v code '%d' "'$char"
        if (( code < 32 )); then
          printf -v hex '%04x' "$code"
          output+="\\u$hex"
        else
          output+="$char"
        fi
        ;;
    esac
  done
  printf '%s"' "$output"
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
  [revealui]=".revealui"
  [cursor]=".cursor"
  [zed]=".zed"
  [vscode]=".vscode"
  [claude]=".claude"
  [grok]=".grok"
  [agents]=".agents"
)

# Build list of editors to check
EDITORS=()
if [[ "$EDITOR" == "all" ]]; then
  for e in revealui cursor zed vscode claude grok agents; do
    should_skip_editor "$e" && continue
    EDITORS+=("$e")
  done
else
  if [[ -z "${EDITOR_DIRS[$EDITOR]+x}" ]]; then
    echo "Error: unknown editor: $EDITOR (expected revealui, cursor, zed, vscode, claude, grok, or agents)"
    exit 1
  fi
  if should_skip_editor "$EDITOR"; then
    echo "Error: editor $EDITOR is in REVCON_SKIP_EDITORS / --skip"
    exit 1
  fi
  EDITORS=("$EDITOR")
fi

# --- Discovery ---

# Scan sibling projects of this revcon checkout for links and copy manifests.
discover_targets() {
  for dir in "$FLEET_DIR"/*/; do
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

# Hash of a projected file after a leading "generated from" marker line.
# Files without that marker are hashed whole.
projection_body_hash() {
  local file="$1" first
  IFS= read -r first < "$file" || true
  if [[ "$first" == "<!-- generated from .revealui/content/"* && "$first" == *"-->" ]]; then
    tail -n +2 "$file" | sha256sum | awk '{print $1}'
  else
    sha256sum < "$file" | awk '{print $1}'
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
        local manifest_rows
        if ! manifest_rows="$(jq -s -r '
          if length == 1 and (.[0] | type == "object")
             and (.[0].mode == "copy")
             and (.[0].profiles | type == "array")
             and all(.[0].profiles[]; type == "string")
             and (.[0].files | type == "object")
             and all(.[0].files[]; type == "object" and (.source | type == "string") and (.sha256 | type == "string"))
             and all(.[0].files | keys[]; length > 0 and (test("[[:cntrl:]]") | not))
             and all(.[0].files[]; .source | test("[[:cntrl:]]") | not)
          then .[0].files | to_entries[] | @base64
          else error("invalid copy manifest") end
        ' "$manifest" 2>/dev/null)"; then
          if ! $JSON; then
            echo "  [$e] invalid copy manifest"
          else
            local ej
            ej=$(printf '"%s":{"mode":"copy","materialized":null,"error":"invalid manifest"}' "$e")
            if [[ -n "$json_editors" ]]; then json_editors="$json_editors,$ej"; else json_editors="$ej"; fi
          fi
          VERIFY_BAD=$((VERIFY_BAD + 1))
          continue
        fi
        local m_total=0 m_ok=0 m_bad=0
        local m_profiles=""
        m_profiles="$(jq -r '.profiles | join(", ")' "$manifest" 2>/dev/null || true)"
        while IFS= read -r encoded; do
          [[ -n "$encoded" ]] || continue
          local row rel src_rel want_hash generated_from
          row="$(printf '%s' "$encoded" | base64 -d)"
          rel="$(jq -r '.key' <<< "$row")"
          src_rel="$(jq -r '.value.source' <<< "$row")"
          want_hash="$(jq -r '.value.sha256' <<< "$row")"
          generated_from="$(jq -r '.value.generatedFrom // empty' <<< "$row")"
          ((m_total++)) || true
          local fpath="$target_dir/$rel"
          local state="ok"
          if [[ -L "$fpath" ]]; then
            state="symlink"
          elif [[ ! -f "$fpath" ]]; then
            state="missing"
          else
            local have_hash
            have_hash="$(sha256sum < "$fpath" | cut -d' ' -f1)"
            if [[ "$have_hash" != "$want_hash" ]]; then
              state="modified"
            else
              local src_abs
              if [[ "$src_rel" == harnesses:* ]]; then
                local content_root
                content_root="$(jq -r '.contentRoot // "content"' "$target/.revealui/manager.json" 2>/dev/null)"
                src_abs="$target/.revealui/$content_root/${src_rel#harnesses:}"
              elif [[ "$src_rel" == private:* ]]; then
                src_abs="$PRIVATE_PROFILES_DIR/${src_rel#private:}"
              else
                src_abs="$SCRIPT_DIR/$src_rel"
              fi
              if [[ ! -f "$src_abs" ]]; then
                state="orphaned"
              else
                local src_hash body_hash
                src_hash="$(sha256sum < "$src_abs" | cut -d' ' -f1)"
                if [[ -n "$generated_from" ]]; then
                  body_hash="$(projection_body_hash "$fpath")"
                  [[ "$body_hash" == "$src_hash" ]] || state="stale"
                else
                  [[ "$src_hash" == "$want_hash" ]] || state="stale"
                fi
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
            fe=$(printf '{"name":%s,"source":%s,"state":%s}' "$(json_quote "$rel")" "$(json_quote "$src_rel")" "$(json_quote "$state")")
            if [[ -n "$files_json" ]]; then files_json="$files_json,$fe"; else files_json="$fe"; fi
          fi
        done <<< "$manifest_rows"
        if ! $JSON; then
          echo "  [$e] $m_total materialized, $m_ok ok, $m_bad drifted (mode: copy, profiles: $m_profiles)"
          printf '%b' "$files_human"
        else
          local ej
          ej=$(printf '"%s":{"mode":"copy","materialized":%d,"ok":%d,"drifted":%d,"profiles":%s,"files":[%s]}' \
            "$e" "$m_total" "$m_ok" "$m_bad" "$(json_quote "$m_profiles")" "$files_json")
          if [[ -n "$json_editors" ]]; then json_editors="$json_editors,$ej"; else json_editors="$ej"; fi
        fi
        if $VERIFY && (( m_bad > 0 )); then
          VERIFY_BAD=$((VERIFY_BAD + m_bad))
        fi
      else
        if ! $JSON; then
          echo "  [$e] materialized (mode: copy) - jq not found, cannot verify"
        else
          local ej
          ej=$(printf '"%s":{"mode":"copy","materialized":null,"error":"jq not found"}' "$e")
          if [[ -n "$json_editors" ]]; then json_editors="$json_editors,$ej"; else json_editors="$ej"; fi
        fi
        if $VERIFY; then
          VERIFY_BAD=$((VERIFY_BAD + 1))
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
          fe=$(printf '{"name":%s,"source":%s,"ok":true}' "$(json_quote "$rel_name")" "$(json_quote "$source_rel")")
        else
          fe=$(printf '{"name":%s,"source":%s,"ok":false}' "$(json_quote "$rel_name")" "$(json_quote "$source_rel")")
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
        pj="$(json_quote "$profile")"
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
    tj=$(printf '{"path":%s,"editors":{%s}}' "$(json_quote "$target")" "$json_editors")
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

if $VERIFY; then
  if (( VERIFY_BAD > 0 )); then
    echo "verify: FAIL — $VERIFY_BAD copy-mode drift(s) (or unreadable manifest)" >&2
    exit 1
  fi
  if ! $JSON; then
    echo "verify: OK — no copy-mode drift reported"
  fi
fi
