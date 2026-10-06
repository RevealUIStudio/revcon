#!/usr/bin/env bash
# check-client-leaks.sh
#
# Scans the repo for any reference to a specific RevealUI Studio client,
# prospect, or warm-intro contact. Customer/prospect names belong in the
# private internal repo only, never in this public surface.
#
# Exit 0 on clean. Exit 1 on any violation. Exit 2 on tool/setup error
# (including a missing pattern list).
#
# Usage:
#   bash scripts/check-client-leaks.sh                     # scan repo root
#   bash scripts/check-client-leaks.sh <path> [<path>...]  # scan specific paths
#   LEAK_JSON=1 bash scripts/check-client-leaks.sh         # machine-readable
#
# CI wiring: .github/workflows/check-client-leaks.yml
# REQUIRED status check on `test` and `main` branch protection.
#
# Adding a client / prospect / contact:
#   Add one line to the CLIENT_LEAK_PATTERNS org Actions secret
#   (format: tag|literal-string|reason). Never add the line to a committed
#   file. Locally, the same lines may live in the gitignored file
#   .client-name-watchlist.local. CI ignores that file and fails closed
#   when CLIENT_LEAK_PATTERNS is missing or empty.
#
# There is no .leakignore for this scanner. The property must be unconditional.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCAN_PATHS=("$@")
[[ ${#SCAN_PATHS[@]} -eq 0 ]] && SCAN_PATHS=("$REPO_ROOT")

for _path in "${SCAN_PATHS[@]}"; do
  if [[ ! -e "$_path" ]]; then
    echo "[client-leak] error: scan path not found: $_path" >&2
    exit 2
  fi
done
unset _path

# --- Patterns: tag | literal-string | reason ---
#
# REGEX-CONFIG-BOUNDARY: the strings consumed by grep -F (fixed strings),
# so each pattern is a literal substring. No metacharacter handling.
# No regex authored.
#
# The list is not stored in this file. CI reads CLIENT_LEAK_PATTERNS.
# A local checkout may use .client-name-watchlist.local instead.
fail_closed_missing_secret() {
  echo "[client-leak] error: CLIENT_LEAK_PATTERNS is empty or unset. CI fails closed until the org Actions secret CLIENT_LEAK_PATTERNS is set and visible to this repo." >&2
  exit 2
}

load_patterns() {
  local in_ci=0 raw="" line trimmed tag rest literal watch
  if [[ "${CI:-}" == "true" || "${GITHUB_ACTIONS:-}" == "true" ]]; then
    in_ci=1
  fi

  raw="${CLIENT_LEAK_PATTERNS-}"
  if [[ -z "${raw//[[:space:]]/}" ]]; then
    raw=""
  fi

  if [[ -z "$raw" ]]; then
    if (( in_ci == 1 )); then
      fail_closed_missing_secret
    fi
    watch="$REPO_ROOT/.client-name-watchlist.local"
    if [[ ! -f "$watch" ]]; then
      echo "[client-leak] warning: no pattern list. Set CLIENT_LEAK_PATTERNS or create the gitignored file .client-name-watchlist.local. Refusing to report a clean scan." >&2
      exit 2
    fi
    raw="$(<"$watch")"
    if [[ -z "${raw//[[:space:]]/}" ]]; then
      echo "[client-leak] warning: .client-name-watchlist.local has no pattern lines. Refusing to report a clean scan." >&2
      exit 2
    fi
  fi

  PATTERNS=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    trimmed="${line#"${line%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    [[ -z "$trimmed" || "$trimmed" == \#* ]] && continue
    if [[ "$trimmed" != *"|"*"|"* ]]; then
      echo "[client-leak] error: each pattern line must use tag|literal|reason. Fix CLIENT_LEAK_PATTERNS or .client-name-watchlist.local." >&2
      exit 2
    fi
    tag="${trimmed%%|*}"
    rest="${trimmed#*|}"
    literal="${rest%%|*}"
    if [[ -z "$tag" || -z "$literal" ]]; then
      echo "[client-leak] error: a pattern line has an empty tag or literal. Fix CLIENT_LEAK_PATTERNS or .client-name-watchlist.local." >&2
      exit 2
    fi
    PATTERNS+=("$trimmed")
  done <<< "$raw"

  if (( ${#PATTERNS[@]} == 0 )); then
    if (( in_ci == 1 )); then
      fail_closed_missing_secret
    fi
    echo "[client-leak] warning: pattern list has no usable lines. Refusing to report a clean scan." >&2
    exit 2
  fi
}

load_patterns

# Directories / file globs to skip
EXCLUDE_DIRS=(node_modules .git dist build .next .turbo .pnpm coverage target .direnv .nyc_output playwright-report test-results)
EXCLUDE_FILES=(
  pnpm-lock.yaml package-lock.json yarn.lock Cargo.lock
  # Local pattern source. It is gitignored and holds the same literals the
  # scan is looking for, so it must not count as a public leak.
  .client-name-watchlist.local
  CHANGELOG.md
  '*.png' '*.jpg' '*.jpeg' '*.gif' '*.webp' '*.pdf' '*.zip' '*.tar.gz' '*.tgz'
  '*.ico' '*.woff' '*.woff2' '*.ttf' '*.otf'
  '*.har' '*.snap'
)

if ! command -v grep >/dev/null 2>&1; then
  echo "[client-leak] error: grep not found on PATH" >&2
  exit 2
fi

grep_excludes=()
for d in "${EXCLUDE_DIRS[@]}"; do
  grep_excludes+=(--exclude-dir="$d")
done
for f in "${EXCLUDE_FILES[@]}"; do
  grep_excludes+=(--exclude="$f")
done

violations=0
json_entries=()

for entry in "${PATTERNS[@]}"; do
  tag="${entry%%|*}"
  rest="${entry#*|}"
  pattern="${rest%%|*}"
  reason="${rest#*|}"

  scan_output="$(grep -rFIn "${grep_excludes[@]}" -- "$pattern" "${SCAN_PATHS[@]}" 2>/dev/null)"
  scan_status=$?
  if (( scan_status > 1 )); then
    echo "[client-leak] error: grep could not complete the requested scan" >&2
    exit 2
  fi
  while IFS= read -r hit; do
    [[ -z "$hit" ]] && continue
    file="${hit%%:*}"
    rest_="${hit#*:}"
    line="${rest_%%:*}"
    content="${rest_#*:}"

    if [[ -n "${LEAK_JSON:-}" ]]; then
      if command -v jq >/dev/null 2>&1; then
        json_entries+=("$(jq -cn --arg tag "$tag" --arg file "$file" --arg line "$line" --arg reason "$reason" --arg content "$content" \
          '{tag:$tag, file:$file, line:($line|tonumber), reason:$reason, content:$content}')")
      else
        safe="${content//\\/\\\\}"
        safe="${safe//\"/\\\"}"
        safe="${safe//$'\n'/\\n}"
        safe="${safe//$'\t'/\\t}"
        sreason="${reason//\\/\\\\}"
        sreason="${sreason//\"/\\\"}"
        json_entries+=("{\"tag\":\"$tag\",\"file\":\"$file\",\"line\":$line,\"reason\":\"$sreason\",\"content\":\"$safe\"}")
      fi
    else
      printf '[CLIENT-LEAK:%s] %s:%s - %s\n  -> %s\n' "$tag" "$file" "$line" "$reason" "$content"
    fi
    violations=$((violations+1))
  done <<< "$scan_output"
done

if [[ -n "${LEAK_JSON:-}" ]]; then
  printf '{"violations":%d,"entries":[%s]}\n' "$violations" "$(IFS=,; echo "${json_entries[*]:-}")"
fi

if (( violations > 0 )); then
  if [[ -z "${LEAK_JSON:-}" ]]; then
    echo "" >&2
    echo "[client-leak] FAIL - $violations violation(s)." >&2
    echo "" >&2
    echo "Customer / prospect names must NEVER appear in this public-facing repo." >&2
    echo "Move the content to the private internal repo (or genericize with a" >&2
    echo "placeholder like 'Acme Corp' / 'acme' / 'first customer')." >&2
    echo "" >&2
    echo "If a new client onboards and their name needs scanner coverage, add" >&2
    echo "the pattern line to the CLIENT_LEAK_PATTERNS org Actions secret." >&2
    echo "Never add it to a committed file." >&2
  fi
  exit 1
fi

[[ -z "${LEAK_JSON:-}" ]] && echo "[client-leak] OK - no client/prospect names detected across: ${SCAN_PATHS[*]}"
exit 0
