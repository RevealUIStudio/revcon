#!/usr/bin/env bash
# check-skill-lockstep.sh — GAP-358
#
# Ensures accidental skill multi-copies stay byte-identical.
#
# Canonical source (edit here only):
#   profiles/revealui/claude/skills/<name>/SKILL.md
#
# Lockstep surfaces (must match canonical when present):
#   profiles/revealui/agents/skills/<name>/SKILL.md
#   harnesses/generators/claude-code/.claude/skills/<name>/SKILL.md
#
# INTENTIONAL (not checked here):
#   harnesses/skills/oss/*.md and harnesses/skills/pro/*.md — harness package
#   bodies (tier split, different shape than profile SKILL.md frontmatter).
#
# Exit 0 when all present lockstep copies match. Exit 1 on any drift.
# Usage:
#   bash scripts/check-skill-lockstep.sh
#   bash scripts/sync-skill-copies.sh && bash scripts/check-skill-lockstep.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CANON_ROOT="$REPO_ROOT/profiles/revealui/claude/skills"
AGENTS_ROOT="$REPO_ROOT/profiles/revealui/agents/skills"
GEN_ROOT="$REPO_ROOT/harnesses/generators/claude-code/.claude/skills"

if [[ ! -d "$CANON_ROOT" ]]; then
  echo "[skill-lockstep] error: canonical dir missing: $CANON_ROOT" >&2
  exit 2
fi

fail=0
checked=0
skipped=0

hash_file() {
  sha256sum "$1" | awk '{print $1}'
}

while IFS= read -r -d '' skill_dir; do
  name="$(basename "$skill_dir")"
  canon="$skill_dir/SKILL.md"
  [[ -f "$canon" ]] || continue

  canon_hash="$(hash_file "$canon")"
  surfaces=()
  [[ -f "$AGENTS_ROOT/$name/SKILL.md" ]] && surfaces+=("agents:$AGENTS_ROOT/$name/SKILL.md")
  [[ -f "$GEN_ROOT/$name/SKILL.md" ]] && surfaces+=("generator:$GEN_ROOT/$name/SKILL.md")

  if [[ ${#surfaces[@]} -eq 0 ]]; then
    # claude-only skill (e.g. deploy) — no accidental multi-copy surface
    skipped=$((skipped + 1))
    continue
  fi

  for entry in "${surfaces[@]}"; do
    label="${entry%%:*}"
    path="${entry#*:}"
    other_hash="$(hash_file "$path")"
    checked=$((checked + 1))
    if [[ "$other_hash" != "$canon_hash" ]]; then
      echo "[skill-lockstep] DRIFT skill=$name surface=$label" >&2
      echo "  canonical: $canon" >&2
      echo "  other:     $path" >&2
      echo "  fix:       bash scripts/sync-skill-copies.sh" >&2
      fail=1
    fi
  done
done < <(find "$CANON_ROOT" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)

if (( fail != 0 )); then
  echo "[skill-lockstep] FAIL — drifted copies (checked=$checked). Edit only profiles/revealui/claude/skills/, then run scripts/sync-skill-copies.sh." >&2
  exit 1
fi

echo "[skill-lockstep] OK — $checked lockstep comparison(s), $skipped claude-only skill(s)"
exit 0
