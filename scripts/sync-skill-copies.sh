#!/usr/bin/env bash
# sync-skill-copies.sh — GAP-358
#
# Mirrors each canonical profile skill directory onto the lockstep surfaces:
#   profiles/revealui/revealui/skills/<name>/   (source, every file)
#     → profiles/revealui/agents/skills/<name>/
#     → harnesses/generators/claude-code/.claude/skills/<name>/
#
# Creates a missing destination. Removes files in a destination skill that are
# no longer in the canonical directory. Does not delete harness-owned skills
# that have no profile canonical (db-migrate, preflight).
#
# After editing a shared skill: run this, then check-skill-lockstep.sh.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CANON_ROOT="$REPO_ROOT/profiles/revealui/revealui/skills"
AGENTS_ROOT="$REPO_ROOT/profiles/revealui/agents/skills"
GEN_ROOT="$REPO_ROOT/harnesses/generators/claude-code/.claude/skills"

if [[ ! -d "$CANON_ROOT" ]]; then
  echo "[skill-sync] error: canonical dir missing: $CANON_ROOT" >&2
  exit 2
fi

copied=0
removed=0
skipped=0

mirror_tree() {
  local src="$1" dest="$2" rel
  mkdir -p "$dest"
  while IFS= read -r -d '' file; do
    rel="${file#"$src"/}"
    mkdir -p "$(dirname "$dest/$rel")"
    if [[ -f "$dest/$rel" ]] && cmp -s "$file" "$dest/$rel"; then
      skipped=$((skipped + 1))
      continue
    fi
    cp "$file" "$dest/$rel"
    echo "[skill-sync] updated ${dest#"$REPO_ROOT/"}/$rel"
    copied=$((copied + 1))
  done < <(find "$src" -type f -print0 | sort -z)
  while IFS= read -r -d '' file; do
    rel="${file#"$dest"/}"
    if [[ -f "$src/$rel" ]]; then
      continue
    fi
    rm "$file"
    echo "[skill-sync] removed ${dest#"$REPO_ROOT/"}/$rel"
    removed=$((removed + 1))
  done < <(find "$dest" -type f -print0 | sort -z)
  find "$dest" -type d -empty -delete 2>/dev/null || true
}

while IFS= read -r -d '' skill_dir; do
  name="$(basename "$skill_dir")"
  [[ -f "$skill_dir/SKILL.md" ]] || {
    echo "[skill-sync] error: canonical skill has no SKILL.md: $name" >&2
    exit 1
  }
  mirror_tree "$skill_dir" "$AGENTS_ROOT/$name"
  mirror_tree "$skill_dir" "$GEN_ROOT/$name"
done < <(find "$CANON_ROOT" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)

echo "[skill-sync] done — copied=$copied removed=$removed already-match=$skipped"
exit 0
