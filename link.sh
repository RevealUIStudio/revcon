#!/usr/bin/env bash
# link.sh — Symlink editor configs into a target project.
#
# Usage:
#   ./link.sh --target ~/revealfleet/revealui --profile revealfleet
#   ./link.sh --target ~/revealfleet/revealui --profile revealfleet --profile revealui --editor all
#   ./link.sh --target ~/revealfleet/revforge --editor all       # all adapters, base only
#   ./link.sh --target ~/revealfleet/revealui --editor zed         # zed only
#   ./link.sh --list                                            # show available profiles
#
# Always writes .revealui/content first when native sources exist, then
# generates .claude and .grok as projections of that tree. Each projection
# carries a "generated from .revealui" marker, whatever --editor is passed.
# Other adapters still require --editor NAME or explicit --editor all.
# Creates real directories in the target,
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
EDITOR="revealui"
MODE="symlink"
DRY_RUN=false
SKIP_EDITORS="${REVCON_SKIP_EDITORS:-}"
PRIVATE_PROFILES_DIR="${REVCON_PRIVATE_PROFILES_DIR:-}"

# Naming admission precedes both public and private profile resolution. A
# directory with a retired identity must not restore an accepted alias.
is_shortened_fleet_identity() {
  case "/$1/" in
    *"/"[Rr][Ee][Vv][Ff][Ll][Ee][Ee][Tt]"/"*) return 0 ;;
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
  ./link.sh --target ~/revealfleet/revealui --profile revealfleet
  ./link.sh --target ~/revealfleet/revealui --profile revealfleet --profile revealui --editor all
  ./link.sh --target ~/revealfleet/revforge --profile revealfleet
  ./link.sh --target ~/revealfleet/foo --editor zed
  ./link.sh --dry-run --target ~/revealfleet/foo --profile revealfleet
  REVCON_SKIP_EDITORS=cursor ./link.sh --target ~/revealfleet/foo --profile revealfleet
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
  while IFS= read -r -d '' rel; do
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
  local prefix=""
  [[ "$editor" == "revealui" ]] && prefix="content/"

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
    if [[ "$editor" == "revealui" && "$EDITOR" != "all" ]]; then
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
    if [[ "$editor" == "revealui" && "$EDITOR" != "all" ]]; then
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
}

install_projection_file() {
  local src="$1" dst="$2" native_rel="$3"
  local dst_parent tmp marker
  dst_parent="$(dirname "$dst")"
  if $DRY_RUN; then
    echo "  [project] ${dst#"$TARGET/"} generated from .revealui/$native_rel"
    return 0
  fi
  mkdir -p "$dst_parent"
  if [[ "$MODE" == "copy" ]]; then
    tmp="$(mktemp)"
    if [[ "$native_rel" == *.md || "$native_rel" == *.mdx ]]; then
      marker="<!-- generated from .revealui/${native_rel} -->"
      { printf '%s\n' "$marker"; cat "$src"; } > "$tmp"
    else
      cat "$src" > "$tmp"
    fi
    if [[ -f "$dst" && ! -L "$dst" ]] && cmp -s "$tmp" "$dst"; then
      rm -f "$tmp"
      ((SKIPPED++)) || true
      return 0
    fi
    rm -f "$dst"
    mv "$tmp" "$dst"
    echo "  [project] $(basename "$dst")"
    ((COPIED++)) || true
  else
    if [[ -L "$dst" && "$(readlink "$dst")" == "$src" ]]; then
      ((SKIPPED++)) || true
      return 0
    fi
    ln -sfn "$src" "$dst"
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
  local vendor rel src vendor_rel dot target_dir marker_file tmp
  collect_native_file_map native_map
  [[ ${#native_map[@]} -gt 0 ]] || return 0
  for vendor in claude grok; do
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
    done < <(printf '%s\n' "${!native_map[@]}" | LC_ALL=C sort)
    marker_file="$target_dir/.generated-from"
    if ! $DRY_RUN; then
      tmp="$(mktemp)"
      {
        printf '%s\n' "generated from .revealui/content"
        while IFS= read -r rel; do
          [[ -n "$rel" ]] || continue
          printf '%s generated from .revealui/%s\n' "${rel#content/}" "$rel"
        done < <(printf '%s\n' "${!native_map[@]}" | LC_ALL=C sort)
      } > "$tmp"
      if [[ -f "$marker_file" && ! -L "$marker_file" ]] && cmp -s "$tmp" "$marker_file"; then
        rm -f "$tmp"
      else
        rm -f "$marker_file"
        mv "$tmp" "$marker_file"
        echo "  [marker] ${marker_file#"$TARGET/"}"
      fi
      if [[ "$MODE" == "copy" ]]; then
        write_projection_manifest "$target_dir" "$vendor" native_map
      fi
    fi
  done
}

distribute_editors() {
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
