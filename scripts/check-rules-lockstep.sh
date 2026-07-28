#!/usr/bin/env bash
# check-rules-lockstep.sh — GAP-419
#
# Ensures rule files that exist in BOTH a profiles/ tree and a harnesses/rules/
# tree stay byte-identical, the rules sibling of check-skill-lockstep.sh.
#
# Canonical sources (edit here only):
#   profiles/revealui/claude/rules/<name>.md
#   profiles/revfleet/claude/rules/<name>.md
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
# To check the canonical (~/.claude/rules) vs this repo's profile copies
# (a different, cross-repo comparison that CANNOT be run in CI here — the
# canonical source lives outside this repo): from a fleet dev machine, run
#   diff <(ls ~/.claude/rules/*.md | xargs -n1 basename) \
#        <(ls ~/revfleet/revcon/profiles/{revealui,revfleet}/claude/rules/*.md 2>/dev/null | xargs -n1 basename | sort -u)
# The durable home for that cross-repo check is the control-layer content
# pipeline (GAP-421's content-materialization channel), not a second
# hand-rolled sync script here.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CANON_ROOTS=(
  "$REPO_ROOT/profiles/revealui/claude/rules"
  "$REPO_ROOT/profiles/revfleet/claude/rules"
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
        echo "  fix:       cp '$canon' '$surface'" >&2
        fail=1
      fi
    done
  done < <(find "$canon_root" -mindepth 1 -maxdepth 1 -name '*.md' -print0 | sort -z)
done

skipped=$((skipped + exempted))

if (( fail != 0 )); then
  echo "[rules-lockstep] FAIL — drifted copies (checked=$checked, exempted=$exempted)." >&2
  exit 1
fi

echo "[rules-lockstep] OK — $checked lockstep comparison(s), $exempted intentionally-exempt rule(s)"
exit 0
