#!/usr/bin/env bash
# run-tests.sh — Behavioral test harness for link.sh / unlink.sh / status.sh.
#
# Plain bash, no bats or other new dependencies. Every scenario runs against
# a mktemp-based fake HOME and mktemp-based fake target/repo directories, so
# the real ~/.config, the real ~/revfleet fleet repos, and this checkout's
# own base/ and profiles/ trees are never touched. Each scenario runs the
# scripts against a small fixture "revcon repo" (a copy of link.sh/unlink.sh/
# status.sh plus deterministic base/ and profiles/testprofile/ fixtures) that
# is rebuilt fresh per test, so results do not depend on real profile content
# and cannot drift as the real base/profiles trees change.
#
# Usage: bash test/run-tests.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS_COUNT=0
FAIL_COUNT=0

pass() {
  echo "PASS: $1"
  PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
  echo "FAIL: $1"
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/revcon-test.XXXXXX")"
FAKE_HOME="$TMP_ROOT/home"
FIXTURE_REVCON="$TMP_ROOT/revcon-fixture"
mkdir -p "$FAKE_HOME"

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

# Rebuild the fixture revcon repo: copies of the real scripts (so the tests
# exercise real behavior) plus a small, deterministic base/ and
# profiles/testprofile/ tree the tests fully control.
setup_fixture_repo() {
  rm -rf "$FIXTURE_REVCON"
  mkdir -p "$FIXTURE_REVCON"
  cp "$REPO_ROOT/link.sh" "$REPO_ROOT/unlink.sh" "$REPO_ROOT/status.sh" "$FIXTURE_REVCON/"

  mkdir -p "$FIXTURE_REVCON/base/zed" "$FIXTURE_REVCON/base/cursor"
  echo '{"base":"zed"}' > "$FIXTURE_REVCON/base/zed/settings.json"
  echo '{"base":"cursor"}' > "$FIXTURE_REVCON/base/cursor/environment.json"

  mkdir -p \
    "$FIXTURE_REVCON/profiles/testprofile/zed" \
    "$FIXTURE_REVCON/profiles/testprofile/cursor" \
    "$FIXTURE_REVCON/profiles/testprofile/claude/agents" \
    "$FIXTURE_REVCON/profiles/testprofile/agents"
  echo '{"profile":"zed-tasks"}' > "$FIXTURE_REVCON/profiles/testprofile/zed/tasks.json"
  echo '{"profile":"cursor-config"}' > "$FIXTURE_REVCON/profiles/testprofile/cursor/config.json"
  echo 'agent one' > "$FIXTURE_REVCON/profiles/testprofile/claude/agents/one.md"
  echo 'agents bar' > "$FIXTURE_REVCON/profiles/testprofile/agents/bar.md"
}

# Run a fixture script (link.sh/unlink.sh/status.sh) with HOME pointed at the
# fake home and any real-machine REVCON_* env overrides cleared, so a
# developer's own shell exports (REVCON_SKIP_EDITORS, REVCON_PRIVATE_PROFILES_DIR)
# can never leak into a test run.
run_script() {
  local script="$1"
  shift
  (
    unset REVCON_SKIP_EDITORS REVCON_PRIVATE_PROFILES_DIR
    export HOME="$FAKE_HOME"
    bash "$FIXTURE_REVCON/$script" "$@"
  )
}

json_field() {
  # json_field <json> <jq-filter>
  printf '%s' "$1" | jq -r "$2" 2>/dev/null
}

# ---------------------------------------------------------------------------
# 1. symlink-mode link creates the expected editor config links
# ---------------------------------------------------------------------------
test_symlink_link_creates_expected_links() {
  local name="symlink-mode link creates expected zed/cursor/claude/agents links"
  setup_fixture_repo
  local target="$TMP_ROOT/t1-target"
  mkdir -p "$target"

  local out
  if ! out="$(run_script link.sh --target "$target" --profile testprofile 2>&1)"; then
    fail "$name (link.sh exited non-zero: $out)"
    return
  fi

  local ok=true

  [[ -L "$target/.zed/settings.json" ]] || ok=false
  [[ "$(readlink "$target/.zed/settings.json" 2>/dev/null)" == "$FIXTURE_REVCON/base/zed/settings.json" ]] || ok=false
  [[ -L "$target/.zed/tasks.json" ]] || ok=false
  [[ "$(readlink "$target/.zed/tasks.json" 2>/dev/null)" == "$FIXTURE_REVCON/profiles/testprofile/zed/tasks.json" ]] || ok=false

  [[ -L "$target/.cursor/environment.json" ]] || ok=false
  [[ "$(readlink "$target/.cursor/environment.json" 2>/dev/null)" == "$FIXTURE_REVCON/base/cursor/environment.json" ]] || ok=false
  [[ -L "$target/.cursor/config.json" ]] || ok=false
  [[ "$(readlink "$target/.cursor/config.json" 2>/dev/null)" == "$FIXTURE_REVCON/profiles/testprofile/cursor/config.json" ]] || ok=false

  [[ -L "$target/.claude/agents/one.md" ]] || ok=false
  [[ -L "$target/.agents/bar.md" ]] || ok=false

  # vscode has no base/ or profile content in this fixture, so link_editor's
  # has_base/has_any_profile gate must skip it entirely (no dir created).
  [[ ! -d "$target/.vscode" ]] || ok=false

  # symlinked dirs get gitignored
  [[ -f "$target/.gitignore" ]] || ok=false
  grep -qxF ".zed/" "$target/.gitignore" 2>/dev/null || ok=false
  grep -qxF ".cursor/" "$target/.gitignore" 2>/dev/null || ok=false
  grep -qxF ".claude/" "$target/.gitignore" 2>/dev/null || ok=false
  grep -qxF ".agents/" "$target/.gitignore" 2>/dev/null || ok=false

  if $ok; then pass "$name"; else fail "$name"; fi
}

# ---------------------------------------------------------------------------
# 2. copy-mode materializes files with its manifest, and the sha256 drift
#    check detects a modified file
# ---------------------------------------------------------------------------
test_copy_mode_manifest_and_drift() {
  local name_materialize="copy-mode materializes files with a .revcon-manifest.json"
  local name_drift="sha256 drift check in status.sh detects a locally modified file"
  setup_fixture_repo
  local target="$TMP_ROOT/t2-target"
  mkdir -p "$target"

  local out
  if ! out="$(run_script link.sh --target "$target" --profile testprofile --editor claude --mode copy 2>&1)"; then
    fail "$name_materialize (link.sh exited non-zero: $out)"
    fail "$name_drift (skipped, setup failed)"
    return
  fi

  local file="$target/.claude/agents/one.md"
  local manifest="$target/.claude/.revcon-manifest.json"
  local ok=true

  [[ -f "$file" && ! -L "$file" ]] || ok=false
  [[ -f "$manifest" ]] || ok=false

  local manifest_hash actual_hash
  manifest_hash="$(json_field "$(cat "$manifest" 2>/dev/null)" '.files["agents/one.md"].sha256')"
  actual_hash="$(sha256sum "$file" 2>/dev/null | cut -d' ' -f1)"
  [[ -n "$manifest_hash" && "$manifest_hash" == "$actual_hash" ]] || ok=false

  # copy mode must NOT gitignore the materialized dot-dir (the target repo is
  # expected to track the copies).
  if [[ -f "$target/.gitignore" ]]; then
    grep -qxF ".claude/" "$target/.gitignore" 2>/dev/null && ok=false
  fi

  if $ok; then pass "$name_materialize"; else fail "$name_materialize"; fi

  # Drift: hand-edit the materialized copy, then confirm status.sh flags it.
  echo "locally modified content" > "$file"
  local status_json
  status_json="$(run_script status.sh --target "$target" --editor claude --json 2>&1)"
  local drifted
  drifted="$(json_field "$status_json" '.targets[0].editors.claude.drifted')"
  if [[ "$drifted" == "1" ]]; then
    pass "$name_drift"
  else
    fail "$name_drift (expected drifted=1, got '$drifted'; json=$status_json)"
  fi
}

# ---------------------------------------------------------------------------
# 3. unlink removes only what link created, leaves a pre-existing foreign
#    file untouched
# ---------------------------------------------------------------------------
test_unlink_scoped_removal() {
  local name="unlink removes only revcon-created links and preserves a foreign file"
  setup_fixture_repo
  local target="$TMP_ROOT/t3-target"
  mkdir -p "$target/.zed"
  echo "not managed by revcon" > "$target/.zed/local-notes.txt"

  local out
  if ! out="$(run_script link.sh --target "$target" --profile testprofile 2>&1)"; then
    fail "$name (link.sh exited non-zero: $out)"
    return
  fi
  if ! out="$(run_script unlink.sh --target "$target" 2>&1)"; then
    fail "$name (unlink.sh exited non-zero: $out)"
    return
  fi

  local ok=true
  [[ -f "$target/.zed/local-notes.txt" ]] || ok=false
  grep -qxF "not managed by revcon" "$target/.zed/local-notes.txt" 2>/dev/null || ok=false

  [[ -L "$target/.zed/settings.json" ]] && ok=false
  [[ -L "$target/.zed/tasks.json" ]] && ok=false
  [[ -L "$target/.cursor/environment.json" ]] && ok=false
  [[ -L "$target/.cursor/config.json" ]] && ok=false
  [[ -L "$target/.claude/agents/one.md" ]] && ok=false
  [[ -L "$target/.agents/bar.md" ]] && ok=false

  if $ok; then pass "$name"; else fail "$name"; fi
}

# ---------------------------------------------------------------------------
# 4. status correctly reports in-sync vs drifted
# ---------------------------------------------------------------------------
test_status_in_sync_and_drifted() {
  local name_symlink="status reports symlink-mode target as fully linked"
  local name_copy_sync="status reports copy-mode target as in-sync (0 drifted) before any edit"
  setup_fixture_repo

  local target_sym="$TMP_ROOT/t4-symlink-target"
  mkdir -p "$target_sym"
  run_script link.sh --target "$target_sym" --profile testprofile --editor zed >/dev/null 2>&1

  local json_sym linked
  json_sym="$(run_script status.sh --target "$target_sym" --editor zed --json 2>&1)"
  linked="$(json_field "$json_sym" '.targets[0].editors.zed.linked')"
  if [[ "$linked" == "2" ]]; then
    pass "$name_symlink"
  else
    fail "$name_symlink (expected linked=2, got '$linked'; json=$json_sym)"
  fi

  local target_copy="$TMP_ROOT/t4-copy-target"
  mkdir -p "$target_copy"
  run_script link.sh --target "$target_copy" --profile testprofile --editor claude --mode copy >/dev/null 2>&1

  local json_copy drifted
  json_copy="$(run_script status.sh --target "$target_copy" --editor claude --json 2>&1)"
  drifted="$(json_field "$json_copy" '.targets[0].editors.claude.drifted')"
  if [[ "$drifted" == "0" ]]; then
    pass "$name_copy_sync"
  else
    fail "$name_copy_sync (expected drifted=0, got '$drifted'; json=$json_copy)"
  fi
}

test_status_default_scan_sandboxed_to_fake_home() {
  local name="status.sh default scan (no --target) stays inside the fake HOME/revfleet"
  setup_fixture_repo
  mkdir -p "$FAKE_HOME/revfleet"
  local target="$FAKE_HOME/revfleet/demo-project"
  mkdir -p "$target"
  run_script link.sh --target "$target" --profile testprofile --editor zed >/dev/null 2>&1

  local json count path
  json="$(run_script status.sh --editor zed --json 2>&1)"
  count="$(json_field "$json" '.targets | length')"
  path="$(json_field "$json" '.targets[0].path')"

  if [[ "$count" == "1" && "$path" == "$target" ]]; then
    pass "$name"
  else
    fail "$name (expected 1 target at $target, got count='$count' path='$path'; json=$json)"
  fi
}

# ---------------------------------------------------------------------------
# 5. re-running link is idempotent (no errors, no duplicate state)
# ---------------------------------------------------------------------------
test_link_idempotent_symlink_mode() {
  local name="re-running link.sh (symlink mode) is idempotent"
  setup_fixture_repo
  local target="$TMP_ROOT/t5-target"
  mkdir -p "$target"

  local out1
  if ! out1="$(run_script link.sh --target "$target" --profile testprofile 2>&1)"; then
    fail "$name (first run failed: $out1)"
    return
  fi

  local before
  before="$(find "$target" -type l | sort | while IFS= read -r l; do printf '%s -> %s\n' "$l" "$(readlink "$l")"; done)"

  local out2
  if ! out2="$(run_script link.sh --target "$target" --profile testprofile 2>&1)"; then
    fail "$name (second run failed: $out2)"
    return
  fi

  local after
  after="$(find "$target" -type l | sort | while IFS= read -r l; do printf '%s -> %s\n' "$l" "$(readlink "$l")"; done)"

  local ok=true
  [[ "$before" == "$after" ]] || ok=false
  printf '%s\n' "$out2" | grep -q "^Done: 0 linked" || ok=false

  if $ok; then pass "$name"; else fail "$name (out2: $out2)"; fi
}

test_link_idempotent_copy_mode() {
  local name="re-running link.sh (copy mode) is idempotent (manifest unchanged, 0 copied)"
  setup_fixture_repo
  local target="$TMP_ROOT/t5b-target"
  mkdir -p "$target"

  run_script link.sh --target "$target" --profile testprofile --editor claude --mode copy >/dev/null 2>&1
  local manifest="$target/.claude/.revcon-manifest.json"
  local before
  before="$(cat "$manifest" 2>/dev/null)"

  local out2
  if ! out2="$(run_script link.sh --target "$target" --profile testprofile --editor claude --mode copy 2>&1)"; then
    fail "$name (second run failed: $out2)"
    return
  fi
  local after
  after="$(cat "$manifest" 2>/dev/null)"

  local ok=true
  [[ -n "$before" && "$before" == "$after" ]] || ok=false
  printf '%s\n' "$out2" | grep -q "^Done: 0 copied" || ok=false

  if $ok; then pass "$name"; else fail "$name (out2: $out2)"; fi
}

# ---------------------------------------------------------------------------
# Run all scenarios
# ---------------------------------------------------------------------------
test_symlink_link_creates_expected_links
test_copy_mode_manifest_and_drift
test_unlink_scoped_removal
test_status_in_sync_and_drifted
test_status_default_scan_sandboxed_to_fake_home
test_link_idempotent_symlink_mode
test_link_idempotent_copy_mode

echo ""
echo "== $PASS_COUNT passed, $FAIL_COUNT failed =="

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  exit 1
fi
exit 0
