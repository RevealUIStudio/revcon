#!/usr/bin/env bash
# check-skill-lockstep.sh — GAP-358
#
# Ensures profile skill directories stay byte-identical on every lockstep
# surface. Every file under the skill directory is compared, not only SKILL.md.
#
# Canonical source (edit here only):
#   profiles/revealui/revealui/skills/<name>/
#
# Lockstep surfaces (must match the canonical directory):
#   profiles/revealui/agents/skills/<name>/
#   harnesses/generators/claude-code/.claude/skills/<name>/
#
# Harness-owned generator skills have no profile canonical. They are allowed
# only when named below:
#   db-migrate, preflight
#
# INTENTIONAL (not checked here):
#   harnesses/skills/oss/*.md and harnesses/skills/pro/*.md — harness package
#   bodies (tier split, different shape than profile SKILL.md frontmatter).
#
# Exit 0 when every profile skill matches on both copies. Exit 1 on drift,
# a missing copy, or an unexpected generator-only skill.
# Usage:
#   bash scripts/check-skill-lockstep.sh
#   bash scripts/sync-skill-copies.sh && bash scripts/check-skill-lockstep.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CANON_ROOT="$REPO_ROOT/profiles/revealui/revealui/skills"
AGENTS_ROOT="$REPO_ROOT/profiles/revealui/agents/skills"
GEN_ROOT="$REPO_ROOT/harnesses/generators/claude-code/.claude/skills"
HARNESS_ONLY=(db-migrate preflight)

if [[ ! -d "$CANON_ROOT" ]]; then
  echo "[skill-lockstep] error: canonical dir missing: $CANON_ROOT" >&2
  exit 2
fi

fail=0
checked=0

is_harness_only() {
  local name="$1" allowed
  for allowed in "${HARNESS_ONLY[@]}"; do
    [[ "$name" == "$allowed" ]] && return 0
  done
  return 1
}

compare_tree() {
  local name="$1" src="$2" dest="$3" label="$4" rel
  if [[ ! -d "$dest" ]]; then
    echo "[skill-lockstep] MISSING skill=$name surface=$label" >&2
    echo "  fix: bash scripts/sync-skill-copies.sh" >&2
    fail=1
    return
  fi
  while IFS= read -r -d '' file; do
    rel="${file#"$src"/}"
    checked=$((checked + 1))
    if [[ ! -f "$dest/$rel" ]] || ! cmp -s "$file" "$dest/$rel"; then
      echo "[skill-lockstep] DRIFT skill=$name surface=$label file=$rel" >&2
      echo "  canonical: $file" >&2
      echo "  other:     $dest/$rel" >&2
      echo "  fix:       bash scripts/sync-skill-copies.sh" >&2
      fail=1
    fi
  done < <(find "$src" -type f -print0 | sort -z)
  while IFS= read -r -d '' file; do
    rel="${file#"$dest"/}"
    if [[ -f "$src/$rel" ]]; then
      continue
    fi
    echo "[skill-lockstep] EXTRA skill=$name surface=$label file=$rel" >&2
    echo "  fix:       bash scripts/sync-skill-copies.sh" >&2
    fail=1
  done < <(find "$dest" -type f -print0 | sort -z)
}

while IFS= read -r -d '' skill_dir; do
  name="$(basename "$skill_dir")"
  if [[ ! -f "$skill_dir/SKILL.md" ]]; then
    echo "[skill-lockstep] MISSING skill=$name file=SKILL.md" >&2
    fail=1
    continue
  fi
  compare_tree "$name" "$skill_dir" "$AGENTS_ROOT/$name" "agents"
  compare_tree "$name" "$skill_dir" "$GEN_ROOT/$name" "generator"
done < <(find "$CANON_ROOT" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)

while IFS= read -r -d '' skill_dir; do
  name="$(basename "$skill_dir")"
  if [[ ! -d "$CANON_ROOT/$name" ]]; then
    echo "[skill-lockstep] EXTRA skill=$name surface=agents" >&2
    echo "  fix: move it to profiles/revealui/revealui/skills/ and run scripts/sync-skill-copies.sh" >&2
    fail=1
  fi
done < <(find "$AGENTS_ROOT" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)

while IFS= read -r -d '' skill_dir; do
  name="$(basename "$skill_dir")"
  if [[ -d "$CANON_ROOT/$name" ]]; then
    continue
  fi
  if ! is_harness_only "$name"; then
    echo "[skill-lockstep] EXTRA skill=$name surface=generator" >&2
    echo "  fix: move it to profiles/revealui/revealui/skills/ or list it as harness-owned" >&2
    fail=1
  fi
done < <(find "$GEN_ROOT" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)

if (( fail != 0 )); then
  echo "[skill-lockstep] FAIL - drifted copies (checked=$checked). Edit only profiles/revealui/revealui/skills/, then run scripts/sync-skill-copies.sh." >&2
  exit 1
fi

echo "[skill-lockstep] OK — $checked lockstep file comparison(s)"
exit 0
