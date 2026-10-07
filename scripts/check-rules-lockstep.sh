#!/usr/bin/env bash
# check-rules-lockstep.sh — GAP-419
#
# Ensures rule files that exist in BOTH a profiles/ tree and a harnesses/rules/
# tree stay byte-identical, the rules sibling of check-skill-lockstep.sh.
#
# Canonical sources (edit here only):
#   profiles/revealui/revealui/rules/<name>.md
#   profiles/revealfleet/revealui/rules/<name>.md
#
# Installed reference (this repo's materialized native tree):
#   .revealui/content/
# Vendor homes .claude and .grok are projections of that reference.
#
# Lockstep surfaces (must match a canonical source when the same basename is
# present):
#   harnesses/rules/pro/<name>.md
#   harnesses/rules/oss/<name>.md
#
# INTENTIONAL (not checked here — content is deliberately per-target adapted,
# not accidental drift):
#   agent-dispatch.md — profiles/revealui's copy talks about this repo's own
#   internal coordination hub; harnesses/rules/pro's copy talks about a
#   generic project MASTER_PLAN.md for external consumers who don't have that
#   hub. Add a basename to EXEMPT below only with the same kind of rationale
#   (a real per-target content difference), never to silence real drift.
#
# harnesses/generators/claude-code/.claude/rules/ and
# harnesses/generators/cursor/.cursor/rules/ are a separate, already-drifted
# materialization mechanism (create-revealui / harnesses.manifest.json).
# Out of scope here; see GAP-421 (harnesses zero-consumer module audit) for
# that mechanism's owning follow-up.
#
# Exit 0 when all present lockstep copies match. Exit 1 on any drift.
#
# Usage:
#   bash scripts/check-rules-lockstep.sh
#
# The reference tree is .revealui/content. Compare each vendor projection
# (.claude, .grok) to that tree. This script also fails when:
#   - an "Authoritative" line names a vendor home
#   - a manifest source is missing (SRC-GONE) or its bytes drifted (STALE)
#   - a manifest is vendor-first (editor claude/grok without generatedFrom,
#     or a source under profiles/<name>/{claude,grok}/)
#
# Usage:
#   bash scripts/check-rules-lockstep.sh
#   bash scripts/check-rules-lockstep.sh --root /path/to/fixture

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) REPO_ROOT="$(cd "$2" && pwd)"; shift 2 ;;
    -h|--help)
      echo "Usage: check-rules-lockstep.sh [--root DIR]"
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

CANON_ROOTS=(
  "$REPO_ROOT/profiles/revealui/revealui/rules"
  "$REPO_ROOT/profiles/revealfleet/revealui/rules"
)
SURFACE_ROOTS=(
  "$REPO_ROOT/harnesses/rules/pro"
  "$REPO_ROOT/harnesses/rules/oss"
)
EXEMPT=(
  "agent-dispatch.md"
)

is_exempt() {
  local name="$1"
  for e in "${EXEMPT[@]}"; do
    [[ "$name" == "$e" ]] && return 0
  done
  return 1
}

hash_file() {
  sha256sum "$1" | awk '{print $1}'
}

fail=0
checked=0
skipped=0
exempted=0

for canon_root in "${CANON_ROOTS[@]}"; do
  [[ -d "$canon_root" ]] || continue
  while IFS= read -r -d '' canon; do
    name="$(basename "$canon")"

    if is_exempt "$name"; then
      exempted=$((exempted + 1))
      continue
    fi

    canon_hash="$(hash_file "$canon")"
    for surface_root in "${SURFACE_ROOTS[@]}"; do
      surface="$surface_root/$name"
      [[ -f "$surface" ]] || continue
      checked=$((checked + 1))
      surface_hash="$(hash_file "$surface")"
      if [[ "$surface_hash" != "$canon_hash" ]]; then
        echo "[rules-lockstep] DRIFT rule=$name" >&2
        echo "  canonical: $canon" >&2
        echo "  other:     $surface" >&2
        echo "  fix:       regenerate canonical exports and selected native profile rules with revealui-harnesses content export" >&2
        fail=1
      fi
    done
  done < <(find "$canon_root" -mindepth 1 -maxdepth 1 -name '*.md' -print0 | sort -z)
done

skipped=$((skipped + exempted))

projection_body_hash() {
  local file="$1" first
  IFS= read -r first < "$file" || true
  if [[ "$first" == "<!-- generated from .revealui/content/"* && "$first" == *"-->" ]]; then
    tail -n +2 "$file" | sha256sum | awk '{print $1}'
  else
    sha256sum < "$file" | awk '{print $1}'
  fi
}

# Authoritative lines must name the native tree, not a vendor home.
check_authoritative_lines() {
  local roots=() path line n
  for path in "$REPO_ROOT/profiles" "$REPO_ROOT/docs" "$REPO_ROOT/.revealui" "$REPO_ROOT/.claude" "$REPO_ROOT/.grok" "$REPO_ROOT/harnesses" "$REPO_ROOT/README.md"; do
    [[ -e "$path" ]] && roots+=("$path")
  done
  [[ ${#roots[@]} -gt 0 ]] || return 0
  while IFS= read -r -d '' path; do
    n=0
    while IFS= read -r line || [[ -n "$line" ]]; do
      n=$((n + 1))
      [[ "$line" == *Authoritative* ]] || continue
      if [[ "$line" =~ (~/|\$HOME/)?\.(claude|grok|cursor|codex|gemini|windsurf|continue)(/|\`) ]] || [[ "$line" =~ \.(claude|grok)/ ]]; then
        echo "[rules-lockstep] authoritative-vendor $path:$n" >&2
        echo "  $line" >&2
        fail=1
      fi
    done < "$path"
  done < <(find "${roots[@]}" -type f -name '*.md' -print0 | sort -z)
}

check_manifests_and_projections() {
  local manifest editor generated rel src want have body ref native_manifest
  native_manifest="$REPO_ROOT/.revealui/.revcon-manifest.json"
  if [[ -f "$REPO_ROOT/.claude/.revcon-manifest.json" || -f "$REPO_ROOT/.grok/.revcon-manifest.json" ]]; then
    if [[ ! -f "$native_manifest" ]]; then
      echo "[rules-lockstep] vendor-first missing $native_manifest" >&2
      fail=1
    fi
  fi
  local dot
  for dot in .revealui .claude .grok; do
    manifest="$REPO_ROOT/$dot/.revcon-manifest.json"
    [[ -f "$manifest" ]] || continue
    editor="$(jq -r '.editor // empty' "$manifest")"
    generated="$(jq -r '.generatedFrom // empty' "$manifest")"
    if [[ "$editor" == "claude" || "$editor" == "grok" ]]; then
      if [[ "$generated" != ".revealui" && "$generated" != .revealui/* ]]; then
        echo "[rules-lockstep] vendor-first manifest=$manifest editor=$editor" >&2
        fail=1
      fi
    fi
    if [[ "$manifest" == "$native_manifest" && "$editor" != "revealui" ]]; then
      echo "[rules-lockstep] vendor-first manifest=$manifest editor=$editor" >&2
      fail=1
    fi
    while IFS=$'\t' read -r rel src want from; do
      [[ -n "$rel" ]] || continue
      if [[ "$src" =~ ^profiles/[^/]+/(claude|grok)/ ]]; then
        echo "[rules-lockstep] vendor-first source=$src manifest=$manifest" >&2
        fail=1
      fi
      if [[ "$src" == private:* ]]; then
        continue
      fi
      if [[ ! -f "$REPO_ROOT/$src" ]]; then
        echo "[rules-lockstep] SRC-GONE source=$src manifest=$manifest" >&2
        fail=1
        continue
      fi
      local installed="$manifest"
      installed="$(dirname "$manifest")/$rel"
      if [[ ! -f "$installed" || -L "$installed" ]]; then
        echo "[rules-lockstep] SRC-GONE installed=$installed manifest=$manifest" >&2
        fail=1
        continue
      fi
      have="$(hash_file "$installed")"
      if [[ "$have" != "$want" ]]; then
        echo "[rules-lockstep] STALE file=$rel manifest=$manifest" >&2
        fail=1
      fi
      if [[ -n "$from" && "$from" != "null" ]]; then
        body="$(projection_body_hash "$installed")"
        ref="$REPO_ROOT/$from"
        if [[ ! -f "$ref" ]]; then
          echo "[rules-lockstep] SRC-GONE reference=$from manifest=$manifest" >&2
          fail=1
        elif [[ "$body" != "$(hash_file "$ref")" ]] || [[ "$body" != "$(hash_file "$REPO_ROOT/$src")" ]]; then
          echo "[rules-lockstep] STALE file=$rel source=$src reference=$from" >&2
          fail=1
        fi
      elif [[ "$have" != "$(hash_file "$REPO_ROOT/$src")" ]]; then
        echo "[rules-lockstep] STALE file=$rel source=$src" >&2
        fail=1
      fi
    done < <(jq -r '.files | to_entries[] | [.key, .value.source, .value.sha256, (.value.generatedFrom // "")] | @tsv' "$manifest")
  done
}

check_authoritative_lines
check_manifests_and_projections

if (( fail != 0 )); then
  echo "[rules-lockstep] FAIL (checked=$checked, exempted=$exempted)." >&2
  exit 1
fi

echo "[rules-lockstep] OK - $checked lockstep comparison(s), $exempted intentionally-exempt rule(s). Reference: .revealui/content"
exit 0
