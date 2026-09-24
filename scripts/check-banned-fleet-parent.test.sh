#!/usr/bin/env bash
# Proves docs path hygiene: a README example that cites the retired fleet
# parent fails the leak scan, and the same example under ~/revealfleet passes.
# The retired token is quote-split so this tracked file does not cite it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCAN="$ROOT/scripts/check-no-private-leaks.sh"
retired='rev''fleet'

tmpdir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT

fail() {
  echo "check-banned-fleet-parent: $1" >&2
  exit 1
}

# Current tree: README, docs, and recipes already cite ~/revealfleet.
if ! bash "$SCAN" "$ROOT" >"$tmpdir/repo.txt" 2>&1; then
  cat "$tmpdir/repo.txt" >&2
  fail "repo scan should pass"
fi

bad="$tmpdir/bad"
mkdir -p "$bad"
printf '%s\n' "./link.sh --target ~/${retired}/revealui --profile revealui" >"$bad/README.md"
set +e
bash "$SCAN" "$bad/README.md" >"$tmpdir/bad.txt" 2>&1
bad_code=$?
set -e
if [[ "$bad_code" -ne 1 ]]; then
  cat "$tmpdir/bad.txt" >&2
  fail "README citing ~/${retired} should exit 1, got ${bad_code}"
fi
if ! grep -q '\[LEAK:banned-fleet-parent\]' "$tmpdir/bad.txt"; then
  cat "$tmpdir/bad.txt" >&2
  fail "README citing ~/${retired} should emit banned-fleet-parent"
fi

home_bad="$tmpdir/home-bad"
mkdir -p "$home_bad"
printf '%s\n' "cd \$HOME/${retired}/revealui" >"$home_bad/README.md"
set +e
bash "$SCAN" "$home_bad/README.md" >"$tmpdir/home-bad.txt" 2>&1
home_code=$?
set -e
if [[ "$home_code" -ne 1 ]]; then
  cat "$tmpdir/home-bad.txt" >&2
  fail "README citing \$HOME/${retired} should exit 1, got ${home_code}"
fi
if ! grep -q '\[LEAK:banned-fleet-parent\]' "$tmpdir/home-bad.txt"; then
  cat "$tmpdir/home-bad.txt" >&2
  fail "README citing \$HOME/${retired} should emit banned-fleet-parent"
fi

good="$tmpdir/good"
mkdir -p "$good"
printf '%s\n' "./link.sh --target ~/revealfleet/revealui --profile revealui" >"$good/README.md"
if ! bash "$SCAN" "$good/README.md" >"$tmpdir/good.txt" 2>&1; then
  cat "$tmpdir/good.txt" >&2
  fail "$HOME/revealfleet README example should pass"
fi

echo "check-banned-fleet-parent passed"
