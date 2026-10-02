#!/usr/bin/env bash
# run-tests.sh — Behavioral test harness for link.sh / unlink.sh / status.sh.
#
# Plain bash, no bats or other new dependencies. Every scenario runs against
# a mktemp-based fake HOME and mktemp-based fake target/repo directories, so
# the real ~/.config, the real ~/revealfleet fleet repos, and this checkout's
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
  if ! out="$(run_script link.sh --target "$target" --profile testprofile --editor all 2>&1)"; then
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
  if ! out="$(run_script link.sh --target "$target" --profile testprofile --editor all 2>&1)"; then
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

test_status_default_scan_sandboxed_to_fixture_parent() {
  local name="status.sh default scan (no --target) discovers sibling projects"
  setup_fixture_repo
  local target="$TMP_ROOT/demo-project"
  mkdir -p "$target"
  run_script link.sh --target "$target" --profile testprofile --editor zed >/dev/null 2>&1

  local json count found
  json="$(run_script status.sh --editor zed --json 2>&1)"
  count="$(json_field "$json" '.targets | length')"
  found="$(printf '%s' "$json" | jq -r --arg target "$target" 'any(.targets[]; .path == $target)' 2>/dev/null)"

  if [[ "$count" -ge 1 && "$found" == "true" ]]; then
    pass "$name"
  else
    fail "$name (expected $target among discovered siblings, got count='$count'; json=$json)"
  fi
}

test_status_rejects_invalid_copy_manifest() {
  local name="status --verify rejects malformed copy manifest"
  setup_fixture_repo
  local target="$TMP_ROOT/invalid-manifest"
  mkdir -p "$target/.claude"
  printf '{invalid json' > "$target/.claude/.revcon-manifest.json"
  local out
  if out="$(run_script status.sh --target "$target" --editor claude --verify 2>&1)"; then
    fail "$name (unexpected success: $out)"
  elif [[ "$out" == *"invalid copy manifest"* ]]; then
    pass "$name"
  else
    fail "$name (unexpected error: $out)"
  fi
}

test_status_rejects_empty_or_multiple_manifests() {
  local name="status --verify rejects empty and multiple JSON documents"
  setup_fixture_repo
  local target="$TMP_ROOT/invalid-doc-count"
  mkdir -p "$target/.claude"
  local manifest="$target/.claude/.revcon-manifest.json"
  : > "$manifest"
  local empty_rc=0 multiple_rc=0
  run_script status.sh --target "$target" --editor claude --verify >/dev/null 2>&1 || empty_rc=$?
  printf '%s\n%s\n' '{"mode":"copy","profiles":[],"files":{}}' '{"mode":"copy","profiles":[],"files":{}}' > "$manifest"
  run_script status.sh --target "$target" --editor claude --verify >/dev/null 2>&1 || multiple_rc=$?
  if [[ "$empty_rc" -eq 1 && "$multiple_rc" -eq 1 ]]; then
    pass "$name"
  else
    fail "$name (empty exit=$empty_rc, multiple exit=$multiple_rc)"
  fi
}

test_status_copy_manifest_keeps_special_path_bytes() {
  local name="status --verify reads copy paths with quotes and backslashes"
  setup_fixture_repo
  local target="$TMP_ROOT/special-copy-path"
  local rel='agents/quoted"back\slash.md'
  local source_rel='base/zed/quoted"source\path.json'
  mkdir -p "$target/.claude/agents"
  printf 'copy content\n' > "$FIXTURE_REVCON/$source_rel"
  cp "$FIXTURE_REVCON/$source_rel" "$target/.claude/$rel"
  local hash
  hash="$(sha256sum < "$target/.claude/$rel" | cut -d' ' -f1)"
  jq -n --arg rel "$rel" --arg source "$source_rel" --arg hash "$hash" \
    '{mode:"copy",profiles:["testprofile"],files:{($rel):{source:$source,sha256:$hash}}}' \
    > "$target/.claude/.revcon-manifest.json"
  local out rc=0
  out="$(run_script status.sh --target "$target" --editor claude --verify --json 2>&1)" || rc=$?
  local recorded_name recorded_source recorded_state
  recorded_name="$(printf '%s' "$out" | jq -r '.targets[0].editors.claude.files[0].name' 2>/dev/null)"
  recorded_source="$(printf '%s' "$out" | jq -r '.targets[0].editors.claude.files[0].source' 2>/dev/null)"
  recorded_state="$(printf '%s' "$out" | jq -r '.targets[0].editors.claude.files[0].state' 2>/dev/null)"
  if [[ "$rc" -eq 0 && "$recorded_name" == "$rel" && "$recorded_source" == "$source_rel" && "$recorded_state" == "ok" ]]; then
    pass "$name"
  else
    fail "$name (exit=$rc output=$out)"
  fi
}

test_status_json_escapes_target_path() {
  local name="status --json escapes quotes and backslashes in a target path"
  setup_fixture_repo
  local target="$TMP_ROOT/quoted\"target\\path"
  mkdir -p "$target"
  local out
  out="$(run_script status.sh --target "$target" --editor zed --json)"
  if [[ "$(printf '%s' "$out" | jq -er '.targets[0].path' 2>/dev/null)" == "$target" ]]; then
    pass "$name"
  else
    fail "$name (invalid JSON or wrong path: $out)"
  fi
}

test_client_scanner_rejects_grep_failure() {
  local name="client leak scanner rejects an incomplete grep scan"
  local fakebin="$TMP_ROOT/fakebin"
  mkdir -p "$fakebin"
  printf '#!/bin/sh\nexit 2\n' > "$fakebin/grep"
  chmod +x "$fakebin/grep"
  local target="$TMP_ROOT/client-scan"
  mkdir -p "$target"
  local out rc=0
  out="$(PATH="$fakebin:$PATH" bash "$REPO_ROOT/scripts/check-client-leaks.sh" "$target" 2>&1)" || rc=$?
  if [[ "$rc" -eq 2 && "$out" == *"could not complete"* ]]; then
    pass "$name"
  else
    fail "$name (exit=$rc output=$out)"
  fi
}

# Unrelated HOME roots must not be treated as checkout siblings.
test_status_default_scan_ignores_home_roots() {
  local name="status.sh default scan uses the checkout parent, not HOME roots"
  setup_fixture_repo
  local sibling="$TMP_ROOT/root-check-project"
  mkdir -p "$sibling"
  run_script link.sh --target "$sibling" --profile testprofile --editor zed >/dev/null 2>&1
  local nested="$FAKE_HOME/revealfleet/demo-project"
  mkdir -p "$nested"
  run_script link.sh --target "$nested" --profile testprofile --editor zed >/dev/null 2>&1
  local retired="${FAKE_HOME}/unrelated-root"
  mkdir -p "$retired/demo-project"
  run_script link.sh --target "$retired/demo-project" --profile testprofile --editor zed >/dev/null 2>&1

  local json
  json="$(run_script status.sh --editor zed --json 2>&1)"
  if printf '%s' "$json" | jq -e --arg sibling "$sibling" --arg nested "$nested" --arg retired "$retired/demo-project" \
    '([.targets[].path] | index($sibling)) != null and ([.targets[].path] | index($nested)) == null and ([.targets[].path] | index($retired)) == null' >/dev/null 2>&1; then
    pass "$name"
  else
    fail "$name (expected sibling only among test roots; json=$json)"
  fi
}

test_canonical_fleet_profile() {
  local name="canonical fleet profile distributes without an alias"
  setup_fixture_repo
  mkdir -p "$FIXTURE_REVCON/profiles/revealfleet/claude"
  echo 'fleet rule' > "$FIXTURE_REVCON/profiles/revealfleet/claude/rule.md"
  local target="$TMP_ROOT/t-fleet"
  mkdir -p "$target"
  local out manifest="$target/.claude/.revcon-manifest.json"
  if ! out="$(run_script link.sh --target "$target" --profile revealfleet --editor claude --mode copy 2>&1)"; then
    fail "$name (copy failed: $out)"; return
  fi
  local ok=true
  jq -e '.profiles == ["revealfleet"] and .files["rule.md"].source == "profiles/revealfleet/claude/rule.md"' "$manifest" >/dev/null || ok=false
  [[ "$(cat "$target/.claude/rule.md")" == 'fleet rule' ]] || ok=false
  run_script link.sh --target "$target" --profile revealfleet --editor claude --mode copy >/dev/null 2>&1 || ok=false
  local linked="$TMP_ROOT/t-fleet-link"
  mkdir -p "$linked"
  run_script link.sh --target "$linked" --profile revealfleet --editor claude >/dev/null 2>&1 || ok=false
  [[ "$(readlink "$linked/.claude/rule.md")" == "$FIXTURE_REVCON/profiles/revealfleet/claude/rule.md" ]] || ok=false
  local listed
  listed="$(run_script link.sh --list)"
  [[ "$listed" == *"revealfleet"* && "$listed" != *"alias"* ]] || ok=false
  if $ok; then pass "$name"; else fail "$name"; fi
}

test_removed_fleet_alias_rejected() {
  local name="removed fleet alias is rejected before target mutation"
  setup_fixture_repo
  mkdir -p "$FIXTURE_REVCON/profiles/revealfleet/claude"
  echo 'fleet rule' > "$FIXTURE_REVCON/profiles/revealfleet/claude/rule.md"
  local target="$TMP_ROOT/t-removed-profile"
  mkdir -p "$target"
  # Synthetic negative input; never a supported profile or path.
  local removed='revfleet' out
  if out="$(run_script link.sh --target "$target" --profile "$removed" --editor claude 2>&1)"; then
    fail "$name (unexpected acceptance)"
  elif [[ "$out" == *"profile not found"* && ! -e "$target/.claude" && ! -e "$target/.gitignore" ]]; then
    pass "$name"
  else
    fail "$name (unexpected error or mutation: $out)"
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
  if ! out1="$(run_script link.sh --target "$target" --profile testprofile --editor all 2>&1)"; then
    fail "$name (first run failed: $out1)"
    return
  fi

  local before
  before="$(find "$target" -type l | sort | while IFS= read -r l; do printf '%s -> %s\n' "$l" "$(readlink "$l")"; done)"

  local out2
  if ! out2="$(run_script link.sh --target "$target" --profile testprofile --editor all 2>&1)"; then
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

test_private_scanner_covers_named_parents() {
  local name="private scanner blocks canonical, historical and renamed coordination paths"
  local target="$TMP_ROOT/private-path-fixture" out rc parent ok=true
  mkdir -p "$target"
  for parent in revealfleet revfleet replacement-fleet; do
    printf '%s/%s/.jv/workboard.md\n' '~' "$parent" > "$target/example.md"
    rc=0
    out="$(bash "$REPO_ROOT/scripts/check-no-private-leaks.sh" "$target" 2>&1)" || rc=$?
    [[ "$rc" -eq 1 && "$out" == *"LEAK:private-jv-repo"* ]] || ok=false
  done
  printf '%s/replacement-fleet/docs/public.md\n$REVEALFLEET_ROOT/.jv/workboard.md\n$root/.jv/workboard.md\n${REVEALFLEET_ROOT}/.jv/workboard.md\n' '~' > "$target/example.md"
  bash "$REPO_ROOT/scripts/check-no-private-leaks.sh" "$target" >/dev/null 2>&1 || ok=false
  if $ok; then pass "$name"; else fail "$name"; fi
}

# ---------------------------------------------------------------------------
test_private_scanner_accepts_public_author_identity() {
  local name="private scanner accepts public author identity and rejects private paths"
  local target="$TMP_ROOT/public-author-fixture" out rc=0
  mkdir -p "$target"
  printf '%s\n' 'Author: founder@revealui.com' > "$target/example.md"
  if ! bash "$REPO_ROOT/scripts/check-no-private-leaks.sh" "$target" >/dev/null 2>&1; then
    fail "$name (public author rejected)"
    return
  fi
  printf '%s\n' '/ho''me/exampleuser/private.md' >> "$target/example.md"
  out="$(bash "$REPO_ROOT/scripts/check-no-private-leaks.sh" "$target" 2>&1)" || rc=$?
  if [[ "$rc" -eq 1 && "$out" == *"LEAK:abs-home-path"* ]]; then
    pass "$name"
  else
    fail "$name (exit=$rc output=$out)"
  fi
}

test_native_policy_requires_content() {
  local name="native selection rejects absent and empty sources before target mutation"
  setup_fixture_repo
  local target="$TMP_ROOT/native-empty" out ok=true selection
  mkdir -p "$target"
  for selection in default explicit empty; do
    local args=()
    [[ "$selection" == default ]] || args=(--editor revealui)
    [[ "$selection" != empty ]] || mkdir -p "$FIXTURE_REVCON/profiles/testprofile/revealui/rules"
    if out="$(run_script link.sh --target "$target" --profile testprofile "${args[@]}" --mode copy 2>&1)"; then ok=false; fi
    [[ "$out" == *"no native RevealUI content"* && ! -e "$target/.revealui" && ! -e "$target/.claude" && ! -e "$target/.gitignore" ]] || ok=false
  done
  run_script link.sh --target "$target" --profile testprofile --editor all --mode copy >/dev/null 2>&1 || ok=false
  [[ -f "$target/.claude/agents/example.md" || -d "$target/.claude" ]] || ok=false
  $ok && pass "$name" || fail "$name"
}

test_native_policy_distribution() {
  local name="default native-only policy copy, provenance, status, drift, idempotence and safe unlink"
  setup_fixture_repo
  mkdir -p "$FIXTURE_REVCON/profiles/revealfleet/revealui/rules"
  echo 'native fleet policy' > "$FIXTURE_REVCON/profiles/revealfleet/revealui/rules/policy.md"
  local target="$TMP_ROOT/native-policy" ok=true out before after
  mkdir -p "$target"
  run_script link.sh --target "$target" --profile revealfleet --mode copy >/dev/null 2>&1 || ok=false
  [[ -f "$target/.revealui/content/rules/policy.md" && ! -e "$target/.claude" && ! -e "$target/.cursor" && ! -e "$target/.zed" && ! -e "$target/.agents" && ! -e "$target/.vscode" ]] || ok=false
  local manifest="$target/.revealui/.revcon-manifest.json"
  jq -e '.editor == "revealui" and .files["content/rules/policy.md"].source == "profiles/revealfleet/revealui/rules/policy.md"' "$manifest" >/dev/null || ok=false
  before="$(cat "$manifest")"
  out="$(run_script link.sh --target "$target" --profile revealfleet --editor revealui --mode copy 2>&1)" || ok=false
  after="$(cat "$manifest")"
  [[ "$before" == "$after" && "$out" == *"0 copied"* ]] || ok=false
  run_script status.sh --target "$target" --editor revealui --verify >/dev/null 2>&1 || ok=false
  echo 'local change' >> "$target/.revealui/content/rules/policy.md"
  if run_script status.sh --target "$target" --editor revealui --verify >/dev/null 2>&1; then ok=false; fi
  run_script unlink.sh --target "$target" --editor revealui >/dev/null 2>&1 || ok=false
  [[ -f "$target/.revealui/content/rules/policy.md" && -f "$manifest" ]] || ok=false
  $ok && pass "$name" || fail "$name"
}

test_native_policy_manifest_admission() {
  local name="native copy lockstep rejects forged ownership and tracked strays"
  setup_fixture_repo
  mkdir -p "$FIXTURE_REVCON/profiles/revealfleet/revealui/rules"
  echo 'native fleet policy' > "$FIXTURE_REVCON/profiles/revealfleet/revealui/rules/policy.md"
  local target="$TMP_ROOT/native-admission" ok=true manifest
  mkdir -p "$target"
  git -C "$target" init -q
  run_script link.sh --target "$target" --profile revealfleet --editor revealui --mode copy >/dev/null 2>&1 || ok=false
  manifest="$target/.revealui/.revcon-manifest.json"
  git -C "$target" add .revealui
  bash "$REPO_ROOT/scripts/verify-copy-lockstep.sh" --target "$target" --dot .revealui >/dev/null 2>&1 || ok=false
  echo 'stray' > "$target/.revealui/content/rules/stray.md"
  git -C "$target" add .revealui/content/rules/stray.md
  if bash "$REPO_ROOT/scripts/verify-copy-lockstep.sh" --target "$target" --dot .revealui >/dev/null 2>&1; then ok=false; fi
  git -C "$target" rm --cached -q .revealui/content/rules/stray.md
  jq '.files["content/rules/policy.md"].source = "profiles/revealfleet/claude/rules/policy.md"' "$manifest" > "$target/forged.json"
  mv "$target/forged.json" "$manifest"
  if bash "$REPO_ROOT/scripts/verify-copy-lockstep.sh" --target "$target" --dot .revealui >/dev/null 2>&1; then ok=false; fi
  $ok && pass "$name" || fail "$name"
}

test_native_policy_real_profile() {
  local name="canonical14 fleet rules materialize natively with exact provenance"
  setup_fixture_repo
  mkdir -p "$FIXTURE_REVCON/profiles/revealfleet/revealui"
  cp -R "$REPO_ROOT/profiles/revealfleet/revealui/rules" "$FIXTURE_REVCON/profiles/revealfleet/revealui/"
  local target="$TMP_ROOT/native-real-profile" ok=true
  mkdir -p "$target"
  run_script link.sh --target "$target" --profile revealfleet --editor revealui --mode copy >/dev/null 2>&1 || ok=false
  jq -e '.editor == "revealui" and (.files | length == 14) and all(.files | to_entries[]; (.key | startswith("content/rules/")) and (.value.source | startswith("profiles/revealfleet/revealui/rules/")))' "$target/.revealui/.revcon-manifest.json" >/dev/null || ok=false
  run_script status.sh --target "$target" --editor revealui --verify >/dev/null 2>&1 || ok=false
  [[ ! -e "$target/.claude" ]] || ok=false
  $ok && pass "$name" || fail "$name"
}

test_native_unlink_rejects_manifest_escape() {
  local name="native unlink refuses manifest path escape before deleting files"
  setup_fixture_repo
  local target="$TMP_ROOT/native-unlink-escape" outside="$TMP_ROOT/native-keep.md" ok=true hash
  mkdir -p "$target/.revealui"
  echo 'must remain' > "$outside"
  hash="$(sha256sum < "$outside" | cut -d' ' -f1)"
  jq -n --arg hash "$hash" '{mode:"copy",editor:"revealui",profiles:["revealfleet"],files:{"../../native-keep.md":{source:"profiles/revealfleet/revealui/rules/policy.md",sha256:$hash}}}' > "$target/.revealui/.revcon-manifest.json"
  if run_script unlink.sh --target "$target" --editor revealui >/dev/null 2>&1; then ok=false; fi
  [[ -f "$outside" && -f "$target/.revealui/.revcon-manifest.json" ]] || ok=false
  $ok && pass "$name" || fail "$name"
}

test_native_policy_claude_projection() {
  local name="optional Claude projection uses native policy and retains unique overlays"
  setup_fixture_repo
  mkdir -p "$FIXTURE_REVCON/profiles/revealfleet/revealui/rules" "$FIXTURE_REVCON/profiles/revealfleet/claude/rules"
  echo 'native policy' > "$FIXTURE_REVCON/profiles/revealfleet/revealui/rules/policy.md"
  echo 'vendor collision' > "$FIXTURE_REVCON/profiles/revealfleet/claude/rules/policy.md"
  echo 'vendor only' > "$FIXTURE_REVCON/profiles/revealfleet/claude/rules/unique.md"
  local target="$TMP_ROOT/native-projection" ok=true
  mkdir -p "$target"
  run_script link.sh --target "$target" --profile revealfleet --editor claude --mode copy >/dev/null 2>&1 || ok=false
  [[ "$(cat "$target/.claude/rules/policy.md")" == 'native policy' ]] || ok=false
  [[ "$(cat "$target/.claude/rules/unique.md")" == 'vendor only' ]] || ok=false
  [[ ! -e "$target/.revealui" ]] || ok=false
  jq -e '.files["rules/policy.md"].source == "profiles/revealfleet/revealui/rules/policy.md" and .files["rules/unique.md"].source == "profiles/revealfleet/claude/rules/unique.md"' "$target/.claude/.revcon-manifest.json" >/dev/null || ok=false
  run_script status.sh --target "$target" --editor claude --verify >/dev/null 2>&1 || ok=false
  $ok && pass "$name" || fail "$name"
}

test_native_policy_symlink_safety() {
  local name="native policy refuses escaped destinations and unlinks only owned symlinks"
  setup_fixture_repo
  mkdir -p "$FIXTURE_REVCON/profiles/revealfleet/revealui/rules"
  echo 'native' > "$FIXTURE_REVCON/profiles/revealfleet/revealui/rules/policy.md"
  local target="$TMP_ROOT/native-symlink" outside="$TMP_ROOT/native-outside" ok=true
  mkdir -p "$target/.revealui/content" "$outside"
  ln -s "$outside" "$target/.revealui/content/rules"
  if run_script link.sh --target "$target" --profile revealfleet --editor revealui --mode copy >/dev/null 2>&1; then ok=false; fi
  [[ ! -e "$outside/policy.md" ]] || ok=false
  rm "$target/.revealui/content/rules"
  echo 'external manifest' > "$outside/manifest.json"
  ln -s "$outside/manifest.json" "$target/.revealui/.revcon-manifest.json"
  if run_script link.sh --target "$target" --profile revealfleet --editor revealui --mode copy >/dev/null 2>&1; then ok=false; fi
  [[ "$(cat "$outside/manifest.json")" == 'external manifest' ]] || ok=false
  rm "$target/.revealui/.revcon-manifest.json"
  run_script link.sh --target "$target" --profile revealfleet --editor revealui >/dev/null 2>&1 || ok=false
  [[ -L "$target/.revealui/content/rules/policy.md" ]] || ok=false
  ln -s "$outside" "$target/.revealui/content/user-link"
  run_script unlink.sh --target "$target" --editor revealui >/dev/null 2>&1 || ok=false
  [[ ! -L "$target/.revealui/content/rules/policy.md" && -L "$target/.revealui/content/user-link" ]] || ok=false
  $ok && pass "$name" || fail "$name"
}

# Run all scenarios
# ---------------------------------------------------------------------------
test_native_policy_requires_content
test_native_policy_distribution
test_native_policy_manifest_admission
test_native_policy_real_profile
test_native_unlink_rejects_manifest_escape
test_native_policy_claude_projection
test_native_policy_symlink_safety
test_symlink_link_creates_expected_links
test_copy_mode_manifest_and_drift
test_unlink_scoped_removal
test_status_in_sync_and_drifted
test_status_default_scan_sandboxed_to_fixture_parent
test_status_rejects_invalid_copy_manifest
test_status_rejects_empty_or_multiple_manifests
test_status_copy_manifest_keeps_special_path_bytes
test_status_json_escapes_target_path
test_client_scanner_rejects_grep_failure
test_private_scanner_accepts_public_author_identity
test_status_default_scan_ignores_home_roots
test_canonical_fleet_profile
test_removed_fleet_alias_rejected
test_private_scanner_covers_named_parents
test_link_idempotent_symlink_mode
test_link_idempotent_copy_mode

echo ""
if python3 "$REPO_ROOT/test/workflow-distribution.test.py"; then
  pass "shared workflow distribution fixtures"
else
  fail "shared workflow distribution fixtures"
fi

echo "== $PASS_COUNT passed, $FAIL_COUNT failed =="

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  exit 1
fi
exit 0
