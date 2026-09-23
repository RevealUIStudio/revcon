#!/usr/bin/env bash
# Proves GAP-359: an untracked gitignored file is not a leak, and the same
# bytes in a tracked file still fail. A directory that is not a git work
# tree keeps the old behavior and still fails.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCAN="$ROOT/scripts/check-no-private-leaks.sh"
PAYLOAD='/mnt/c/Users/Example/secret'

cleanup() {
  git -C "$ROOT" rm --cached -q -- .claude/settings.local.json leak-scan-fixture/note.txt >/dev/null 2>&1 || true
  rm -f "$ROOT/.claude/settings.local.json"
  rm -rf "$ROOT/leak-scan-fixture"
  rm -rf "$NONGIT"
}
NONGIT=""
trap cleanup EXIT

mkdir -p "$ROOT/.claude"
printf '%s\n' "$PAYLOAD" > "$ROOT/.claude/settings.local.json"
set +e
bash "$SCAN" "$ROOT/.claude" >/tmp/leak-359-ignored.txt
code=$?
set -e
if [[ "$code" -ne 0 ]]; then
  echo "untracked gitignored file should exit 0, got $code" >&2
  cat /tmp/leak-359-ignored.txt >&2
  exit 1
fi

mkdir -p "$ROOT/leak-scan-fixture"
printf '%s\n' "$PAYLOAD" > "$ROOT/leak-scan-fixture/note.txt"
git -C "$ROOT" add -- leak-scan-fixture/note.txt
set +e
bash "$SCAN" "$ROOT/leak-scan-fixture" >/tmp/leak-359-tracked.txt
code=$?
set -e
git -C "$ROOT" rm --cached -q -- leak-scan-fixture/note.txt
rm -rf "$ROOT/leak-scan-fixture"
if [[ "$code" -ne 1 ]]; then
  echo "tracked file should exit 1, got $code" >&2
  cat /tmp/leak-359-tracked.txt >&2
  exit 1
fi

git -C "$ROOT" add -f -- .claude/settings.local.json
set +e
bash "$SCAN" "$ROOT/.claude" >/tmp/leak-359-forced.txt
code=$?
set -e
git -C "$ROOT" rm --cached -q -- .claude/settings.local.json
rm -f "$ROOT/.claude/settings.local.json"
if [[ "$code" -ne 1 ]]; then
  echo "tracked gitignored file should exit 1, got $code" >&2
  cat /tmp/leak-359-forced.txt >&2
  exit 1
fi

NONGIT="$(mktemp -d)"
mkdir -p "$NONGIT/scripts"
cp "$SCAN" "$NONGIT/scripts/check-no-private-leaks.sh"
printf '%s\n' "$PAYLOAD" > "$NONGIT/note.txt"
set +e
bash "$NONGIT/scripts/check-no-private-leaks.sh" "$NONGIT" >/tmp/leak-359-nongit.txt
code=$?
set -e
if [[ "$code" -ne 1 ]]; then
  echo "non-git directory should still exit 1, got $code" >&2
  cat /tmp/leak-359-nongit.txt >&2
  exit 1
fi

echo "check-no-private-leaks gitignore cases passed"
