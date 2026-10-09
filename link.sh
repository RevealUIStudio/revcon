#!/usr/bin/env bash
# link.sh — Materialize editor configs into a target project.
#
# Usage:
#   ./link.sh --target "$REVEALFLEET_ROOT/revealui" --profile revealfleet
#   ./link.sh --target "$REVEALFLEET_ROOT/revealui" --profile revealfleet --profile revealui --editor all
#   ./link.sh --target "$REVEALFLEET_ROOT/revforge" --editor all       # all adapters, base only
#   ./link.sh --target "$REVEALFLEET_ROOT/revealui" --editor zed         # zed only
#   ./link.sh --list                                            # show available profiles
#
# Always writes .revealui/content first when native sources exist, then
# generates .claude and .grok as projections of that tree. Each projection
# carries a "generated from .revealui" marker, whatever --editor is passed.
# Other adapters still require --editor NAME or explicit --editor all.
# Creates real directories in the target,
# then copies individual config files from base/ and optionally one or more
# profile overlays. --profile is repeatable; profiles are applied in the order
# given, and later profiles override earlier ones on filename collisions
# (base → first profile → second profile → ...).
# Explicit legacy symlink mode adds managed dirs to the target's .gitignore.
#
# Copy mode is the default: files are materialized as real copies,
# a deterministic <dot_dir>/.revcon-manifest.json (per-file source + sha256)
# is written, and no .gitignore entry is added: the target repo is expected to
# TRACK the copies and gate drift with a lockstep check against the manifest.
# Re-running with unchanged profiles is a no-op (idempotent apply).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

TARGET=""
PROFILES=()
EDITOR="revealui"
MODE="copy"
DRY_RUN=false
SKIP_EDITORS="${REVCON_SKIP_EDITORS:-}"
PRIVATE_PROFILES_DIR="${REVCON_PRIVATE_PROFILES_DIR:-}"

# Naming admission precedes both public and private profile resolution. A
# directory with a retired identity must not restore an accepted alias.
is_shortened_fleet_identity() {
  # Reject retired spellings as a whole path segment. The canonical identity
  # is longer (revealfleet / RevealFleet / REVEALFLEET) and does not match.
  case "/$1/" in
    *"/"[Rr][Ee][Vv][Ff][Ll][Ee][Ee][Tt]"/"*) return 0 ;;
    *"/"[Rr][Ee][Vv][Ff][Ee][Ee][Tt]"/"*) return 0 ;;
    *) return 1 ;;
  esac
}

usage() {
  cat <<'EOF'
Usage: link.sh [OPTIONS]

Options:
  --target DIR     Project directory to link into (required)
  --profile NAME   Profile overlay (repeatable; later wins on collision)
                   Examples: revealfleet, revealui, revforge
  --editor NAME    Editor to link: revealui, cursor, zed, vscode, claude, grok, agents, all (default: revealui)
                   revealui is always written first when native sources exist.
                   .claude and .grok are projections of that native tree.
  --mode NAME      Distribution mode: copy (default) or legacy symlink. Copy mode
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
  ./link.sh --target "$REVEALFLEET_ROOT/revealui" --profile revealfleet
  ./link.sh --target "$REVEALFLEET_ROOT/revealui" --profile revealfleet --profile revealui --editor all
  ./link.sh --target "$REVEALFLEET_ROOT/revforge" --profile revealfleet
  ./link.sh --target "$REVEALFLEET_ROOT/foo" --editor zed
  ./link.sh --dry-run --target "$REVEALFLEET_ROOT/foo" --profile revealfleet
  REVCON_SKIP_EDITORS=cursor ./link.sh --target "$REVEALFLEET_ROOT/foo" --profile revealfleet
EOF
  exit 0
}

print_profiles() {
  echo "Available profiles:"
  local dir name
  for dir in "$SCRIPT_DIR"/profiles/*/; do
    [[ -d "$dir" ]] || continue
    name="$(basename "$dir")"
    is_shortened_fleet_identity "$name" && continue
    echo "  $name"
  done
  if [[ -n "$PRIVATE_PROFILES_DIR" && -d "$PRIVATE_PROFILES_DIR" ]]; then
    for dir in "$PRIVATE_PROFILES_DIR"/*/; do
      [[ -d "$dir" ]] || continue
      name="$(basename "$dir")"
      is_shortened_fleet_identity "$name" && continue
      echo "  $name (private)"
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
    --profile)
      if is_shortened_fleet_identity "$2"; then
        echo "Error: shortened fleet identity is not supported; use --profile revealfleet" >&2
        exit 1
      fi
      # Names are one directory segment under profiles/ or the private root.
      # A slash or parent segment would resolve outside that directory.
      case "$2" in
        ""|.*|*/*|*\\*)
          echo "Error: profile name must be a single path segment: $2" >&2
          exit 1
          ;;
      esac
      PROFILES+=("$2"); shift 2 ;;
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

if [[ "$MODE" == "copy" ]] && ! command -v jq >/dev/null; then
  echo "Error: copy mode requires jq for structured manifests" >&2
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
  [revealui]=".revealui"
  [cursor]=".cursor"
  [zed]=".zed"
  [vscode]=".vscode"
  [claude]=".claude"
  [grok]=".grok"
  [agents]=".agents"
)

# Shared content is manual Markdown reference material, never auto-loaded rules
# or executable commands. Every adapter supports explicit file reading.
declare -A SHARED_WORKFLOW_DIRS=(
  [cursor]="workflows" [zed]="workflows" [vscode]="workflows"
  [claude]="workflows" [agents]="workflows" [revealui]="content/workflows"
)

LINKED=0
SKIPPED=0
COPIED=0
# Paths left untouched because they are real user files (no generated-from
# marker and no manifest entry). Manifest writers must not claim them.
declare -A PRESERVED_NATIVE=()
declare -A HARNESS_RULES=()
declare -A EXISTING_PROJECTIONS=()

# Admit harness ownership before native or vendor distribution writes anything.
validate_harness_rules() {
  local ownership="$TARGET/.claude/.revcon-manifest.json"
  HARNESS_RULES=()
  [[ -e "$ownership" || -L "$ownership" ]] || return 0
  if [[ -L "$ownership" ]] || ! jq -e '.mode == "copy" and .editor == "claude" and (.files | type == "object") and all(.files[]; (.source | type == "string") and (.sha256 | type == "string"))' "$ownership" >/dev/null; then
    echo "Error: invalid Claude ownership manifest" >&2; exit 1
  fi
  local owned_rel owned_source owned_hash owned_file expected_source canonical content_root
  content_root="$(jq -r '.contentRoot // "content"' "$TARGET/.revealui/manager.json" 2>/dev/null || echo content)"
  while IFS=$'\t' read -r owned_rel owned_source owned_hash; do
    [[ "$owned_source" == harnesses:* ]] || continue
    owned_file="$TARGET/.claude/$owned_rel"
    expected_source="harnesses:$owned_rel"
    canonical="$TARGET/.revealui/$content_root/$owned_rel"
    if [[ "$owned_rel" == "rules/00-revealui-manager.md" ]]; then
      expected_source="harnesses:adapters/claude-code.md"
      canonical="$TARGET/.revealui/adapters/claude-code.md"
    fi
    if [[ "$MODE" != "copy" || "$owned_rel" != rules/*.md || "${owned_rel#rules/}" == */* || "$owned_rel" =~ [[:cntrl:]] || "$owned_source" != "$expected_source" || ! -f "$owned_file" || -L "$owned_file" || "$(realpath -m -- "$owned_file")" != "$owned_file" || "$(sha256sum < "$owned_file" | cut -d' ' -f1)" != "$owned_hash" ]]; then
      echo "Error: invalid or modified harness-owned Claude rule" >&2; exit 1
    fi
    if [[ ! -f "$canonical" || -L "$canonical" || "$(realpath -m -- "$canonical")" != "$canonical" || "$(sha256sum < "$canonical" | cut -d' ' -f1)" != "$owned_hash" ]]; then
      echo "Error: harness-owned Claude content differs from its canonical source" >&2; exit 1
    fi
    HARNESS_RULES["$owned_rel"]=1
  done < <(jq -r '.files | to_entries[] | [.key, .value.source, .value.sha256] | @tsv' "$ownership")
}

declare -A PRESERVED_VENDOR=()
PROJECTION_PRESERVED=0

warn_real_file_skip() {
  local dst="$1"
  echo "  [skip] $(basename "$dst") - real file exists (back up or remove to link)"
  ((SKIPPED++)) || true
}

# A symlink we created points at a file in this revcon tree.
symlink_points_into_profile_tree() {
  local dst="$1" target
  [[ -L "$dst" ]] || return 1
  target="$(readlink -- "$dst")"
  if [[ "$target" != /* ]]; then
    target="$(dirname "$dst")/$target"
  fi
  target="$(realpath -m -- "$target")"
  [[ "$target" == "$SCRIPT_DIR/"* ]]
}

projection_has_generated_marker() {
  local dst="$1" native_rel="$2" first marker
  [[ -f "$dst" && ! -L "$dst" ]] || return 1
  marker="<!-- generated from .revealui/${native_rel} -->"
  IFS= read -r first < "$dst" || true
  [[ "$first" == "$marker" ]]
}

# Non-markdown projections cannot carry an HTML marker. Ownership is the
# manifest generatedFrom entry instead.
projection_manifest_owns() {
  local manifest="$1" rel="$2" from
  [[ -n "$manifest" && -f "$manifest" && ! -L "$manifest" ]] || return 1
  from="$(jq -r --arg rel "$rel" '.files[$rel].generatedFrom // empty' "$manifest" 2>/dev/null || true)"
  [[ -n "$from" && "$from" == .revealui/* ]]
}

projection_real_file_owned() {
  local dst="$1" native_rel="$2" manifest="$3" vendor_rel="$4"
  # Existing hash-verified managed copies can migrate to native projections.
  if [[ -n "${EXISTING_PROJECTIONS[$dst]+x}" ]]; then
    [[ "$(sha256sum < "$dst" | cut -d' ' -f1)" == "${EXISTING_PROJECTIONS[$dst]}" ]]
    return
  fi
  case "$native_rel" in
    *.md|*.mdx) projection_has_generated_marker "$dst" "$native_rel" ;;
    *) projection_manifest_owns "$manifest" "$vendor_rel" ;;
  esac
}

native_manifest_owns() {
  local manifest="$1" rel="$2"
  [[ -f "$manifest" && ! -L "$manifest" ]] || return 1
  jq -e --arg rel "$rel" '.files[$rel] != null' "$manifest" >/dev/null 2>&1
}

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

  local profiles_json files_json='{}' rel src hash
  profiles_json="$(jq -cn --args '$ARGS.positional' "${PROFILES[@]}")"
  if [[ "$editor" == "claude" && -f "$manifest" ]]; then
    files_json="$(jq -c '.files | with_entries(select(.value.source | startswith("harnesses:")))' "$manifest")"
  fi
  while IFS= read -r -d '' rel; do
    [[ -n "${PRESERVED_NATIVE[$rel]+x}" ]] && continue
    [[ -n "$rel" ]] || continue
    src="${fmap[$rel]}"
    hash="$(sha256sum < "$src" | cut -d' ' -f1)"
    files_json="$(jq -cn --argjson files "$files_json" --arg rel "$rel" \
      --arg source "$(manifest_source "$src")" --arg hash "$hash" \
      '$files + {($rel): {source: $source, sha256: $hash}}')"
  done < <(printf '%s\0' "${!fmap[@]}" | sort -z)
  jq -Sn --arg editor "$editor" --argjson profiles "$profiles_json" \
    --argjson files "$files_json" \
    '{mode: "copy", editor: $editor, profiles: $profiles, files: $files}' > "$manifest"
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
    warn_real_file_skip "$dst"
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
  PRESERVED_NATIVE=()
  local dot_dir="${EDITOR_DIRS[$editor]}"
  local base_src="$SCRIPT_DIR/base/$editor"
  local target_dir="$TARGET/$dot_dir"
  local prefix=""
  [[ "$editor" == "revealui" ]] && prefix="content/"
  if [[ "$MODE" == "copy" && -L "$target_dir/.revcon-manifest.json" ]]; then
    echo "Error: copy ownership manifest must be a regular file" >&2
    exit 1
  fi

  # Check if there are any files to link for this editor
  local has_base=false
  local has_any_profile=false
  [[ -d "$base_src" ]] && has_base=true
  for pdir in "${PROFILE_DIRS[@]+"${PROFILE_DIRS[@]}"}"; do
    if [[ -d "$pdir/$editor" || ( "$editor" != "revealui" && ( -d "$pdir/workflows" || -L "$pdir/workflows" ) ) ]]; then
      has_any_profile=true
      break
    fi
  done

  if ! $has_base && ! $has_any_profile; then
    if [[ "$editor" == "revealui" && "$EDITOR" != "all" && ${#HARNESS_RULES[@]} -eq 0 ]]; then
      echo "Error: no native RevealUI content for selected profiles; provide maintained base/revealui or profiles/<profile>/revealui content." >&2
      exit 1
    fi
    return
  fi

  echo "[$editor] → $target_dir"

  if [[ "$editor" == "revealui" && "$MODE" == "copy" && -L "$target_dir/.revcon-manifest.json" ]]; then
    echo "Error: unsafe native policy manifest destination" >&2; exit 1
  fi

  # Collect all source files: base first, then each profile in order.
  # Use an associative array to deduplicate (later overlay wins).
  declare -A file_map=()

  if $has_base; then
    while IFS= read -r -d '' file; do
      local rel="${file#"$base_src/"}"
      file_map["$prefix$rel"]="$file"
    done < <(find "$base_src" -type f -print0 | sort -z)
  fi

  for pdir in "${PROFILE_DIRS[@]+"${PROFILE_DIRS[@]}"}"; do
    local profile_src="$pdir/$editor"
    # Per-profile shared content precedes that profile's adapter overlay.
    local shared_src="$pdir/workflows"
    if [[ "$editor" != "revealui" && -L "$shared_src" ]]; then
      echo "Error: shared workflow root must be a real directory: $shared_src" >&2
      exit 1
    fi
    if [[ "$editor" != "revealui" && -d "$shared_src" ]]; then
      if ! find "$shared_src" -print >/dev/null; then
        echo "Error: cannot enumerate workflow sources: $shared_src" >&2
        exit 1
      fi
      while IFS= read -r -d '' file; do
        [[ -f "$file" && ! -L "$file" && -r "$file" && "$file" == *.md && ! "$file" =~ [[:cntrl:]] ]] || {
          echo "Error: shared workflows require readable Markdown files: $file" >&2
          exit 1
        }
        local rel="${SHARED_WORKFLOW_DIRS[$editor]}/${file#"$shared_src/"}"
        file_map["$rel"]="$file"
      done < <(find "$shared_src" \( -type f -o -type l \) -print0 | sort -z)
    fi
    [[ -d "$profile_src" ]] || continue
    if [[ "$editor" == "revealui" && ( -L "$profile_src" || -n "$(find "$profile_src" -type l -print -quit)" ) ]]; then
      echo "Error: native policy sources must be real files: $profile_src" >&2; exit 1
    fi
    while IFS= read -r -d '' file; do
      local rel="${file#"$profile_src/"}"
      file_map["$prefix$rel"]="$file"
    done < <(find "$profile_src" -type f -print0 | sort -z)
  done

  # Definition rules and their content twins remain owned by the harness.
  local owned_rel
  for owned_rel in "${!HARNESS_RULES[@]}"; do
    if [[ "$editor" == "revealui" ]]; then unset 'file_map[content/$owned_rel]'; fi
    if [[ "$editor" == "claude" ]]; then unset 'file_map[$owned_rel]'; fi
  done

  # Vendor profile files cannot replace native policy. Collisions are
  # dropped here and written later as projections of the native tree.
  if [[ "$editor" == "claude" ]]; then
    for native_src in "$SCRIPT_DIR/base/revealui" "${PROFILE_DIRS[@]/%//revealui}"; do
      [[ -d "$native_src" && ! -L "$native_src" ]] || continue
      while IFS= read -r -d '' file; do
        [[ -f "$file" && ! -L "$file" ]] || continue
        local rel="${file#"$native_src/"}"
        unset "file_map[$rel]"
      done < <(find "$native_src" -type f -print0 | sort -z)
    done
  fi

  if [[ ${#file_map[@]} -eq 0 ]]; then
    if [[ "$editor" == "revealui" && "$EDITOR" != "all" && ${#HARNESS_RULES[@]} -eq 0 ]]; then
      echo "Error: no native RevealUI content files for selected profiles; empty native directories cannot materialize policy." >&2
      exit 1
    fi
    return
  fi

  # Native policy and its projections must not traverse a destination symlink.
  for rel in "${!file_map[@]}"; do
    local src="${file_map[$rel]}" dst="$target_dir/$rel" resolved
    if [[ "$editor" == "revealui" ]]; then
      case "$rel" in content/rules/*|content/agents/*|content/skills/*|content/commands/*) ;;
        *) echo "Error: unsupported native content path: $rel" >&2; exit 1 ;;
      esac
      [[ -f "$src" && ! -L "$src" && -r "$src" ]] || { echo "Error: invalid native policy source" >&2; exit 1; }
    fi
    if [[ "$editor" == "revealui" || "$src" == */revealui/* ]]; then
      resolved="$(realpath -m -- "$(dirname "$dst")")/$(basename "$dst")"
      if [[ -L "$target_dir" || "$resolved" != "$target_dir/"* ]]; then
        echo "Error: unsafe native policy destination: $dst" >&2; exit 1
      fi
    fi
  done

  # The harness package owns its native Codex delivery. RevCon continues to
  # deliver profile-only skills, without becoming a second owner of the pack.
  if [[ "$editor" == "agents" && -f "$TARGET/.revealui/adapters/codex-files.json" ]]; then
    local harness_manifest="$TARGET/.revealui/adapters/codex-files.json"
    if [[ -L "$harness_manifest" ]] || ! jq -e '.version == 1 and (.files | type == "object")' "$harness_manifest" >/dev/null; then
      echo "Error: invalid Codex delivery ownership manifest" >&2
      exit 1
    fi
    for rel in "${!file_map[@]}"; do
      local harness_hash
      harness_hash="$(jq -r --arg path ".agents/$rel" '.files[$path] // empty' "$harness_manifest")"
      [[ -n "$harness_hash" ]] || continue
      local harness_file="$target_dir/$rel"
      if [[ ! -f "$harness_file" || -L "$harness_file" || "$(realpath -m -- "$harness_file")" != "$harness_file" || "$(sha256sum < "$harness_file" | cut -d' ' -f1)" != "$harness_hash" ]]; then
        echo "Error: preserving modified harness-owned skill: $harness_file" >&2
        exit 1
      fi
      unset 'file_map[$rel]'
    done
    if [[ "$MODE" != "copy" ]]; then
      echo "Error: native Codex projects require portable copy delivery" >&2
      exit 1
    fi
  fi

  # Profile skills use the same ownership-preserving migration contract as
  # shared workflow documents. Preflight all files before replacing any.
  if [[ "$MODE" == "copy" || "$editor" == "agents" ]]; then
    for rel in "${!file_map[@]}"; do
      [[ "$rel" == "${SHARED_WORKFLOW_DIRS[$editor]}/"* ]] && continue
      local dst="$target_dir/$rel" resolved
      resolved="$(realpath -m -- "$(dirname "$dst")")/$(basename "$dst")"
      if [[ "$rel" =~ [[:cntrl:]] || -L "$target_dir" || "$resolved" != "$dst" || "$rel" == ../* || "$rel" == */../* ]]; then
        echo "Error: unsafe native skill destination: $dst" >&2
        exit 1
      fi
      if [[ -L "$dst" ]]; then
        local source_rel existing
        source_rel="${file_map[$rel]#"$SCRIPT_DIR/"}"
        existing="$(readlink "$dst")"
        if [[ "$existing" != "${file_map[$rel]}" && "$existing" != */revcon/"$source_rel" ]]; then
          echo "Error: preserving foreign native skill symlink: $dst" >&2
          exit 1
        fi
      elif [[ -e "$dst" ]]; then
        if [[ "$editor" == "revealui" ]] && ! native_manifest_owns "$target_dir/.revcon-manifest.json" "$rel"; then
          continue
        fi
        local copy_manifest="$target_dir/.revcon-manifest.json" previous_hash=""
        if [[ -f "$copy_manifest" && ! -L "$copy_manifest" ]]; then
          previous_hash="$(jq -r --arg rel "$rel" '.files[$rel].sha256 // empty' "$copy_manifest")"
        fi
        if [[ ! -f "$dst" || -z "$previous_hash" || "$(sha256sum < "$dst" | cut -d' ' -f1)" != "$previous_hash" ]]; then
          echo "Error: preserving unowned or modified native skill: $dst" >&2
          exit 1
        fi
      fi
    done
  fi

  # Shared/manual documents preserve user ownership during migration. A copy
  # is managed only while its manifest hash still matches; external symlinks
  # and unrecorded files are never adopted, even if their bytes match.
  for rel in "${!file_map[@]}"; do
    [[ "$rel" == "${SHARED_WORKFLOW_DIRS[$editor]}/"* ]] || continue
    if [[ "$rel" =~ [[:cntrl:]] ]]; then
      echo "Error: workflow paths cannot contain control characters" >&2
      exit 1
    fi
    local dst="$target_dir/$rel" resolved
    resolved="$(realpath -m -- "$(dirname "$dst")")/$(basename "$dst")"
    if [[ -L "$target_dir" || "$resolved" != "$target_dir/"* ]]; then
      echo "Error: unsafe workflow destination: $dst" >&2
      exit 1
    fi
    if [[ -L "$dst" ]]; then
      local existing
      existing="$(readlink "$dst")"
      [[ "$existing" == /* ]] || existing="$(dirname "$dst")/$existing"
      existing="$(realpath -m -- "$existing")"
      local managed=false candidate
      candidate="$(realpath -m -- "$base_src/$rel")"
      [[ "$existing" == "$candidate" ]] && managed=true
      for pdir in "${PROFILE_DIRS[@]}"; do
        for candidate in "$pdir/$editor/$rel" "$pdir/workflows/${rel#"${SHARED_WORKFLOW_DIRS[$editor]}/"}"; do
          [[ "$existing" == "$(realpath -m -- "$candidate")" ]] && managed=true
        done
      done
      if ! $managed; then
        echo "Error: preserving user workflow symlink: $dst" >&2
        exit 1
      fi
    elif [[ -e "$dst" ]]; then
      local manifest="$target_dir/.revcon-manifest.json" want_hash=""
      if [[ -f "$manifest" && ! -L "$manifest" ]] && command -v jq >/dev/null; then
        want_hash="$(jq -r --arg rel "$rel" '.files[$rel].sha256 // empty' "$manifest" 2>/dev/null || true)"
      fi
      if [[ "$MODE" == "symlink" ]]; then
        echo "Error: unlink verified workflow copies before switching to symlink mode: $dst" >&2
        exit 1
      fi
      if [[ ! -f "$dst" || -z "$want_hash" || "$(sha256sum < "$dst" | cut -d' ' -f1)" != "$want_hash" ]]; then
        echo "Error: preserving unowned or modified workflow: $dst" >&2
        exit 1
      fi
    fi
  done

  # Create real directory only after source and destination admission.
  if ! $DRY_RUN; then
    mkdir -p "$target_dir"
  fi

  # Create subdirectories and symlink files
  while IFS= read -r -d '' rel; do
    [[ -n "$rel" ]] || continue
    local src="${file_map[$rel]}"
    local dst="$target_dir/$rel"
    local dst_parent
    dst_parent="$(dirname "$dst")"

    if ! $DRY_RUN; then
      mkdir -p "$dst_parent"
    fi

    if [[ "$MODE" == "copy" && "$editor" == "revealui" && -e "$dst" && ! -L "$dst" ]]; then
      if ! native_manifest_owns "$target_dir/.revcon-manifest.json" "$rel"; then
        warn_real_file_skip "$dst"
        PRESERVED_NATIVE["$rel"]=1
        continue
      fi
    fi

    if [[ "$MODE" == "copy" ]]; then
      copy_file "$src" "$dst"
    else
      link_file "$src" "$dst"
    fi
  done < <(printf '%s\0' "${!file_map[@]}" | sort -z)

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

# True when base or a selected profile has at least one real native file.
native_policy_available() {
  local base_src="$SCRIPT_DIR/base/revealui" pdir
  if [[ -d "$base_src" && -n "$(find "$base_src" -type f -print -quit)" ]]; then
    return 0
  fi
  for pdir in "${PROFILE_DIRS[@]+"${PROFILE_DIRS[@]}"}"; do
    [[ -d "$pdir/revealui" && ! -L "$pdir/revealui" ]] || continue
    [[ -n "$(find "$pdir/revealui" -type f -print -quit)" ]] && return 0
  done
  return 1
}

# rel under .revealui (content/...) -> absolute source path.
collect_native_file_map() {
  local -n _dest=$1
  local base_src="$SCRIPT_DIR/base/revealui" pdir profile_src file rel
  if [[ -d "$base_src" ]]; then
    while IFS= read -r -d '' file; do
      rel="content/${file#"$base_src/"}"
      _dest["$rel"]="$file"
    done < <(find "$base_src" -type f -print0 | sort -z)
  fi
  for pdir in "${PROFILE_DIRS[@]+"${PROFILE_DIRS[@]}"}"; do
    profile_src="$pdir/revealui"
    [[ -d "$profile_src" && ! -L "$profile_src" ]] || continue
    while IFS= read -r -d '' file; do
      [[ -f "$file" && ! -L "$file" ]] || continue
      rel="content/${file#"$profile_src/"}"
      _dest["$rel"]="$file"
    done < <(find "$profile_src" -type f -print0 | sort -z)
  done
  local owned_rel
  for owned_rel in "${!HARNESS_RULES[@]}"; do unset '_dest[content/$owned_rel]'; done
}

install_projection_file() {
  local src="$1" dst="$2" native_rel="$3"
  local dst_parent tmp marker manifest vendor_rel action
  PROJECTION_PRESERVED=0
  dst_parent="$(dirname "$dst")"
  manifest=""
  vendor_rel=""
  case "$dst" in
    "$TARGET/.claude/"*)
      vendor_rel="${dst#"$TARGET/.claude/"}"
      manifest="$TARGET/.claude/.revcon-manifest.json"
      ;;
    "$TARGET/.grok/"*)
      vendor_rel="${dst#"$TARGET/.grok/"}"
      manifest="$TARGET/.grok/.revcon-manifest.json"
      ;;
  esac

  # Symlink mode never uses ln -sf over a regular file. Copy mode overwrites
  # only a projection that already carries its generated-from marker.
  action="create"
  if [[ -L "$dst" ]]; then
    if [[ "$MODE" != "copy" && "$(readlink -- "$dst")" == "$src" ]]; then
      ((SKIPPED++)) || true
      return 0
    fi
    if symlink_points_into_profile_tree "$dst"; then
      action="replace-symlink"
    else
      action="preserve"
    fi
  elif [[ -e "$dst" ]]; then
    if [[ "$MODE" == "copy" && -f "$dst" ]] && projection_real_file_owned "$dst" "$native_rel" "$manifest" "$vendor_rel"; then
      action="replace-owned"
    else
      action="preserve"
    fi
  fi

  if [[ "$action" == "preserve" ]]; then
    warn_real_file_skip "$dst"
    PROJECTION_PRESERVED=1
    return 0
  fi

  if $DRY_RUN; then
    echo "  [project] ${dst#"$TARGET/"} generated from .revealui/$native_rel"
    return 0
  fi

  mkdir -p "$dst_parent"
  if [[ "$action" == "replace-symlink" ]]; then
    rm -- "$dst"
  fi

  if [[ "$MODE" == "copy" ]]; then
    tmp="$(mktemp)"
    if [[ "$native_rel" == *.md || "$native_rel" == *.mdx ]]; then
      marker="<!-- generated from .revealui/${native_rel} -->"
      { printf '%s\n' "$marker"; cat -- "$src"; } > "$tmp"
    else
      cat -- "$src" > "$tmp"
    fi
    if [[ "$action" == "replace-owned" && -f "$dst" && ! -L "$dst" ]] && cmp -s "$tmp" "$dst"; then
      rm -f "$tmp"
      ((SKIPPED++)) || true
      return 0
    fi
    mv "$tmp" "$dst"
    echo "  [project] $(basename "$dst")"
    ((COPIED++)) || true
  else
    ln -s "$src" "$dst"
    echo "  [project] $(basename "$dst")"
    ((LINKED++)) || true
  fi
}

write_projection_manifest() {
  local target_dir="$1" editor="$2"
  local -n nmap=$3
  local manifest="$target_dir/.revcon-manifest.json"
  local files_json='{}' existing_json='{}' rel src vendor_rel hash source from entry profiles_json
  if [[ -f "$manifest" && ! -L "$manifest" ]]; then
    existing_json="$(jq -c '.files // {}' "$manifest")"
  fi
  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    [[ -n "${nmap[content/$rel]+x}" ]] && continue
    [[ -f "$target_dir/$rel" && ! -L "$target_dir/$rel" ]] || continue
    entry="$(jq -c --arg rel "$rel" '.[$rel]' <<<"$existing_json")"
    files_json="$(jq -nc --argjson files "$files_json" --arg rel "$rel" --argjson entry "$entry" \
      '$files + {($rel): $entry}')"
  done < <(jq -r 'keys[]' <<<"$existing_json")
  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    src="${nmap[$rel]}"
    vendor_rel="${rel#content/}"
    [[ -n "${PRESERVED_VENDOR[$vendor_rel]+x}" ]] && continue
    hash="$(sha256sum < "$target_dir/$vendor_rel" | cut -d' ' -f1)"
    source="$(manifest_source "$src")"
    from=".revealui/$rel"
    files_json="$(jq -nc --argjson files "$files_json" --arg rel "$vendor_rel" \
      --arg source "$source" --arg hash "$hash" --arg from "$from" \
      '$files + {($rel): {source: $source, sha256: $hash, generatedFrom: $from}}')"
  done < <(printf '%s\n' "${!nmap[@]}" | LC_ALL=C sort)
  if [[ ${#PROFILES[@]} -eq 0 ]]; then
    profiles_json='[]'
  else
    profiles_json="$(jq -cn --args '$ARGS.positional' "${PROFILES[@]}")"
  fi
  jq -Sn --arg editor "$editor" --argjson profiles "$profiles_json" --argjson files "$files_json" \
    '{mode: "copy", editor: $editor, generatedFrom: ".revealui", profiles: $profiles, files: $files}' > "$manifest"
  echo "  [manifest] ${manifest#"$TARGET/"}"
}

# .claude and .grok are generated from the native tree. They are not sources.
project_native_vendors() {
  local -A native_map=()
  local vendor rel src vendor_rel dot target_dir marker_file tmp marker_first
  collect_native_file_map native_map
  [[ ${#native_map[@]} -gt 0 ]] || return 0
  for vendor in claude grok; do
    PRESERVED_VENDOR=()
    dot="${EDITOR_DIRS[$vendor]}"
    target_dir="$TARGET/$dot"
    echo "[$vendor] projection generated from .revealui/content -> $target_dir"
    if ! $DRY_RUN; then
      mkdir -p "$target_dir"
    fi
    while IFS= read -r rel; do
      [[ -n "$rel" ]] || continue
      src="${native_map[$rel]}"
      install_projection_file "$src" "$target_dir/${rel#content/}" "$rel"
      if [[ "$PROJECTION_PRESERVED" == 1 ]]; then
        PRESERVED_VENDOR["${rel#content/}"]=1
      fi
    done < <(printf '%s\n' "${!native_map[@]}" | LC_ALL=C sort)
    marker_file="$target_dir/.generated-from"
    if ! $DRY_RUN; then
      tmp="$(mktemp)"
      {
        printf '%s\n' "generated from .revealui/content"
        while IFS= read -r rel; do
          [[ -n "$rel" ]] || continue
          [[ -n "${PRESERVED_VENDOR[${rel#content/}]+x}" ]] && continue
          printf '%s generated from .revealui/%s\n' "${rel#content/}" "$rel"
        done < <(printf '%s\n' "${!native_map[@]}" | LC_ALL=C sort)
      } > "$tmp"
      if [[ -L "$marker_file" ]]; then
        if symlink_points_into_profile_tree "$marker_file"; then
          rm -- "$marker_file"
          mv "$tmp" "$marker_file"
          echo "  [marker] ${marker_file#"$TARGET/"}"
        else
          rm -f "$tmp"
          warn_real_file_skip "$marker_file"
        fi
      elif [[ -f "$marker_file" ]]; then
        marker_first=""
        IFS= read -r marker_first < "$marker_file" || true
        if [[ "$marker_first" != "generated from .revealui/content" ]]; then
          rm -f "$tmp"
          warn_real_file_skip "$marker_file"
        elif cmp -s "$tmp" "$marker_file"; then
          rm -f "$tmp"
        else
          mv "$tmp" "$marker_file"
          echo "  [marker] ${marker_file#"$TARGET/"}"
        fi
      elif [[ -e "$marker_file" ]]; then
        rm -f "$tmp"
        warn_real_file_skip "$marker_file"
      else
        mv "$tmp" "$marker_file"
        echo "  [marker] ${marker_file#"$TARGET/"}"
      fi
      if [[ "$MODE" == "copy" ]]; then
        write_projection_manifest "$target_dir" "$vendor" native_map
      fi
    fi
  done
}

# Retain ownership evidence before vendor overlay manifests are rewritten.
# This is runtime state from the existing ledger, never a second owner store.
snapshot_projection_ownership() {
  local -A native_map=()
  local vendor manifest rel source hash dst
  EXISTING_PROJECTIONS=()
  collect_native_file_map native_map
  for vendor in claude grok; do
    manifest="$TARGET/.$vendor/.revcon-manifest.json"
    [[ -f "$manifest" && ! -L "$manifest" ]] || continue
    while IFS=$'\t' read -r rel source hash; do
      [[ -n "${native_map[content/$rel]+x}" ]] || continue
      [[ "$source" != harnesses:* ]] || continue
      dst="$TARGET/.$vendor/$rel"
      [[ -f "$dst" && ! -L "$dst" ]] || continue
      if [[ "$(realpath -m -- "$dst")" != "$dst" || "$(sha256sum < "$dst" | cut -d' ' -f1)" != "$hash" ]]; then
        echo "Error: modified managed vendor file; cannot migrate native projection" >&2
        exit 1
      fi
      EXISTING_PROJECTIONS["$dst"]="$hash"
    done < <(jq -r '.files | to_entries[] | [.key, .value.source, .value.sha256] | @tsv' "$manifest")
  done
}

distribute_editors() {
  validate_harness_rules
  snapshot_projection_ownership
  case "$EDITOR" in
    revealui|claude|grok)
      link_editor revealui
      if [[ "$EDITOR" == "claude" ]] && ! should_skip_editor claude; then
        link_editor claude
      fi
      ;;
    all)
      if native_policy_available; then
        link_editor revealui
      fi
      local e
      for e in cursor zed vscode claude agents; do
        if should_skip_editor "$e"; then
          echo "[$e] skipped (REVCON_SKIP_EDITORS / --skip)"
          continue
        fi
        link_editor "$e"
      done
      ;;
    *)
      if native_policy_available; then
        link_editor revealui
      fi
      if should_skip_editor "$EDITOR"; then
        echo "[$EDITOR] skipped (REVCON_SKIP_EDITORS / --skip)"
      else
        link_editor "$EDITOR"
      fi
      ;;
  esac
  if native_policy_available; then
    project_native_vendors
  fi
}

# Run
echo "Linking editor configs → $TARGET"
if [[ ${#PROFILES[@]} -gt 0 ]]; then
  echo "Profiles: ${PROFILES[*]}  (later overrides earlier on collision)"
fi
$DRY_RUN && echo "(dry run)"
echo ""

if [[ "$EDITOR" != "all" && -z "${EDITOR_DIRS[$EDITOR]+x}" ]]; then
  echo "Error: unknown editor: $EDITOR" >&2; exit 1
fi

distribute_editors

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
  for e in revealui cursor zed vscode claude agents; do
    should_skip_editor "$e" && continue
    if [[ "$MODE" == "copy" ]]; then
      warn_if_ignored "${EDITOR_DIRS[$e]}"
    else
      if [[ "$e" == "revealui" ]]; then ensure_gitignored ".revealui/content/"; else ensure_gitignored "${EDITOR_DIRS[$e]}/"; fi
    fi
  done
else
  if ! should_skip_editor "$EDITOR"; then
    if [[ "$MODE" == "copy" ]]; then
      warn_if_ignored "${EDITOR_DIRS[$EDITOR]}"
    else
      if [[ "$EDITOR" == "revealui" ]]; then ensure_gitignored ".revealui/content/"; else ensure_gitignored "${EDITOR_DIRS[$EDITOR]}/"; fi
    fi
  fi
fi

# Native policy and its projections are written even when --editor names
# another adapter. Ignore those trees in symlink mode once they exist.
if [[ "$MODE" != "copy" ]]; then
  [[ -d "$TARGET/.revealui" ]] && ensure_gitignored ".revealui/content/"
  [[ -d "$TARGET/.claude" ]] && ensure_gitignored ".claude/"
  [[ -d "$TARGET/.grok" ]] && ensure_gitignored ".grok/"
fi

echo ""
if [[ "$MODE" == "copy" ]]; then
  echo "Done: $COPIED copied, $SKIPPED unchanged"
else
  echo "Done: $LINKED linked, $SKIPPED unchanged"
fi
