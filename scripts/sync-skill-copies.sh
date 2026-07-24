#!/usr/bin/env bash
# sync-skill-copies.sh — GAP-358
#
# Copies canonical profile skills into lockstep surfaces:
#   profiles/revealui/claude/skills/<name>/SKILL.md  (source)
#     → profiles/revealui/agents/skills/<name>/SKILL.md
#     → harnesses/generators/claude-code/.claude/skills/<name>/SKILL.md
#
# Only syncs skills that already exist on a surface (does not invent new skills
# on agents/generators). Safe to re-run (idempotent).
#
# After editing a shared skill: run this, then check-skill-lockstep.sh.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CANON_ROOT="$REPO_ROOT/profiles/revealui/claude/skills"
AGENTS_ROOT="$REPO_ROOT/profiles/revealui/agents/skills"
GEN_ROOT="$REPO_ROOT/harnesses/generators/claude-code/.claude/skills"

if [[ ! -d "$CANON_ROOT" ]]; then
  echo "[skill-sync] error: canonical dir missing: $CANON_ROOT" >&2
  exit 2
fi

copied=0
skipped=0

while IFS= read -r -d '' skill_dir; do
  name="$(basename "$skill_dir")"
  canon="$skill_dir/SKILL.md"
  [[ -f "$canon" ]] || continue

  for dest_root in "$AGENTS_ROOT" "$GEN_ROOT"; do
    dest="$dest_root/$name/SKILL.md"
    if [[ ! -f "$dest" ]]; then
      continue
    fi
    if cmp -s "$canon" "$dest"; then
      skipped=$((skipped + 1))
      continue
    fi
    mkdir -p "$(dirname "$dest")"
    cp "$canon" "$dest"
    echo "[skill-sync] updated ${dest#"$REPO_ROOT/"}"
    copied=$((copied + 1))
  done
done < <(find "$CANON_ROOT" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)

echo "[skill-sync] done — copied=$copied already-match=$skipped"
exit 0
