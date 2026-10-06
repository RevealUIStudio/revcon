#!/usr/bin/env bash
# Native-first distribution: .revealui is written first and .claude/.grok
# are projections, for the default run, --editor claude, --editor grok,
# and --mode copy. Also checks lockstep failures.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/revcon-native-first.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

setup_fixture() {
  local repo="$TMP_ROOT/revcon"
  rm -rf "$repo"
  mkdir -p "$repo/profiles/sample/revealui/rules" "$repo/profiles/sample/claude/rules"
  cp "$REPO_ROOT/link.sh" "$repo/link.sh"
  printf 'native policy\n' > "$repo/profiles/sample/revealui/rules/policy.md"
  printf 'vendor only\n' > "$repo/profiles/sample/claude/rules/unique.md"
  printf 'vendor collision\n' > "$repo/profiles/sample/claude/rules/policy.md"
  printf '%s' "$repo"
}

run_link() {
  local repo="$1"
  shift
  env -u REVCON_SKIP_EDITORS -u REVCON_PRIVATE_PROFILES_DIR \
    bash "$repo/link.sh" "$@"
}

assert_native_first() {
  local name="$1" out="$2" target="$3" mode="$4"
  local ok=true
  [[ -f "$target/.revealui/content/rules/policy.md" ]] || ok=false
  [[ -f "$target/.claude/.generated-from" && -f "$target/.grok/.generated-from" ]] || ok=false
  grep -q 'generated from .revealui/content' "$target/.claude/.generated-from" || ok=false
  grep -q 'generated from .revealui/content' "$target/.grok/.generated-from" || ok=false
  grep -q 'rules/policy.md generated from .revealui/content/rules/policy.md' "$target/.claude/.generated-from" || ok=false
  [[ "${out%%\[claude\]*}" == *"[revealui]"* ]] || ok=false
  [[ "${out%%\[grok\]*}" == *"[revealui]"* ]] || ok=false
  [[ "$(cat "$target/.revealui/content/rules/policy.md")" == "native policy" ]] || ok=false
  if [[ "$mode" == "copy" ]]; then
    [[ "$(head -n 1 "$target/.claude/rules/policy.md")" == "<!-- generated from .revealui/content/rules/policy.md -->" ]] || ok=false
    [[ "$(tail -n +2 "$target/.claude/rules/policy.md")" == "native policy" ]] || ok=false
    [[ "$(head -n 1 "$target/.grok/rules/policy.md")" == "<!-- generated from .revealui/content/rules/policy.md -->" ]] || ok=false
    jq -e '.editor == "revealui" and .files["content/rules/policy.md"].source == "profiles/sample/revealui/rules/policy.md"' \
      "$target/.revealui/.revcon-manifest.json" >/dev/null || ok=false
    jq -e '.editor == "claude" and .generatedFrom == ".revealui" and .files["rules/policy.md"].generatedFrom == ".revealui/content/rules/policy.md" and .files["rules/policy.md"].source == "profiles/sample/revealui/rules/policy.md"' \
      "$target/.claude/.revcon-manifest.json" >/dev/null || ok=false
    jq -e '.editor == "grok" and .generatedFrom == ".revealui"' \
      "$target/.grok/.revcon-manifest.json" >/dev/null || ok=false
  else
    [[ -L "$target/.revealui/content/rules/policy.md" && -L "$target/.claude/rules/policy.md" && -L "$target/.grok/rules/policy.md" ]] || ok=false
  fi
  if $ok; then pass "$name"; else fail "$name"; fi
}

test_default_run() {
  local repo target out
  repo="$(setup_fixture)"
  target="$TMP_ROOT/default"
  mkdir -p "$target"
  if ! out="$(run_link "$repo" --target "$target" --profile sample 2>&1)"; then
    fail "default run writes native first (link failed: $out)"
    return
  fi
  assert_native_first "default run writes native first" "$out" "$target" symlink
}

test_editor_claude() {
  local repo target out
  repo="$(setup_fixture)"
  target="$TMP_ROOT/claude"
  mkdir -p "$target"
  if ! out="$(run_link "$repo" --target "$target" --profile sample --editor claude 2>&1)"; then
    fail "--editor claude writes native first (link failed: $out)"
    return
  fi
  assert_native_first "--editor claude writes native first" "$out" "$target" symlink
  [[ "$(cat "$target/.claude/rules/unique.md")" == "vendor only" ]] && pass "--editor claude keeps a non-colliding overlay" || fail "--editor claude keeps a non-colliding overlay"
}

test_editor_claude_without_native_does_not_write_vendor() {
  local repo="$TMP_ROOT/vendor-only" target="$TMP_ROOT/vendor-only-target" out
  mkdir -p "$repo/profiles/sample/claude/rules" "$target"
  cp "$REPO_ROOT/link.sh" "$repo/link.sh"
  printf 'vendor\n' > "$repo/profiles/sample/claude/rules/only.md"
  if out="$(run_link "$repo" --target "$target" --profile sample --editor claude 2>&1)"; then
    fail "--editor claude without native content is rejected (unexpected success)"
  elif [[ "$out" == *"no native RevealUI content"* && ! -e "$target/.claude" && ! -e "$target/.revealui" && ! -e "$target/.grok" ]]; then
    pass "--editor claude without native content is rejected"
  else
    fail "--editor claude without native content is rejected ($out)"
  fi
}

test_editor_grok() {
  local repo target out
  repo="$(setup_fixture)"
  target="$TMP_ROOT/grok"
  mkdir -p "$target"
  if ! out="$(run_link "$repo" --target "$target" --profile sample --editor grok 2>&1)"; then
    fail "--editor grok writes native first (link failed: $out)"
    return
  fi
  assert_native_first "--editor grok writes native first" "$out" "$target" symlink
}

test_mode_copy() {
  local repo target out
  repo="$(setup_fixture)"
  target="$TMP_ROOT/copy"
  mkdir -p "$target"
  if ! out="$(run_link "$repo" --target "$target" --profile sample --mode copy 2>&1)"; then
    fail "--mode copy writes native first (link failed: $out)"
    return
  fi
  assert_native_first "--mode copy writes native first" "$out" "$target" copy
  run_link "$repo" --target "$target" --profile sample --editor claude --mode copy >/dev/null 2>&1 || true
  if ! out="$(run_link "$repo" --target "$target" --profile sample --editor claude --mode copy 2>&1)"; then
    fail "--mode copy --editor claude is idempotent ($out)"
  elif [[ "$out" == *"0 copied"* ]]; then
    pass "--mode copy --editor claude is idempotent"
  else
    fail "--mode copy --editor claude is idempotent ($out)"
  fi
}

test_lockstep_failures() {
  local root="$TMP_ROOT/lockstep" script="$REPO_ROOT/scripts/check-rules-lockstep.sh"
  rm -rf "$root"
  mkdir -p "$root/profiles/sample/revealui/rules" "$root/docs" "$root/.claude/rules" "$root/.revealui/content/rules"
  printf 'native\n' > "$root/profiles/sample/revealui/rules/policy.md"
  cp "$root/profiles/sample/revealui/rules/policy.md" "$root/.revealui/content/rules/policy.md"
  local hash
  hash="$(sha256sum < "$root/profiles/sample/revealui/rules/policy.md" | awk '{print $1}')"
  jq -n --arg hash "$hash" '{mode:"copy",editor:"revealui",profiles:["sample"],files:{"content/rules/policy.md":{source:"profiles/sample/revealui/rules/policy.md",sha256:$hash}}}' \
    > "$root/.revealui/.revcon-manifest.json"

  printf 'Authoritative rule: `~/.claude/rules/policy.md`\n' > "$root/docs/bad.md"
  local out rc
  rc=0
  out="$(bash "$script" --root "$root" 2>&1)" || rc=$?
  if [[ "$rc" -eq 1 && "$out" == *"authoritative-vendor"* ]]; then
    pass "lockstep fails when Authoritative names a vendor path"
  else
    fail "lockstep fails when Authoritative names a vendor path (exit=$rc $out)"
  fi
  rm "$root/docs/bad.md"

  jq -n '{mode:"copy",editor:"claude",profiles:["sample"],files:{"rules/policy.md":{source:"profiles/sample/claude/rules/policy.md",sha256:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}}' \
    > "$root/.claude/.revcon-manifest.json"
  printf 'x\n' > "$root/.claude/rules/policy.md"
  rc=0
  out="$(bash "$script" --root "$root" 2>&1)" || rc=$?
  if [[ "$rc" -eq 1 && "$out" == *"vendor-first"* && "$out" == *"SRC-GONE"* ]]; then
    pass "lockstep fails on a vendor-first manifest and a gone source"
  else
    fail "lockstep fails on a vendor-first manifest and a gone source (exit=$rc $out)"
  fi

  local marked have
  marked="$(printf '%s\n%s\n' '<!-- generated from .revealui/content/rules/policy.md -->' 'stale body')"
  printf '%s\n' "$marked" > "$root/.claude/rules/policy.md"
  have="$(sha256sum < "$root/.claude/rules/policy.md" | awk '{print $1}')"
  jq -n --arg hash "$have" '{mode:"copy",editor:"claude",generatedFrom:".revealui",profiles:["sample"],files:{"rules/policy.md":{source:"profiles/sample/revealui/rules/policy.md",sha256:$hash,generatedFrom:".revealui/content/rules/policy.md"}}}' \
    > "$root/.claude/.revcon-manifest.json"
  rc=0
  out="$(bash "$script" --root "$root" 2>&1)" || rc=$?
  if [[ "$rc" -eq 1 && "$out" == *"STALE"* ]]; then
    pass "lockstep fails when a projection is stale against .revealui/content"
  else
    fail "lockstep fails when a projection is stale against .revealui/content (exit=$rc $out)"
  fi
}

test_lockstep_repo() {
  local out rc=0
  out="$(bash "$REPO_ROOT/scripts/check-rules-lockstep.sh" 2>&1)" || rc=$?
  if [[ "$rc" -eq 0 && "$out" == *"Reference: .revealui/content"* ]]; then
    pass "repo lockstep accepts the native reference"
  else
    fail "repo lockstep accepts the native reference (exit=$rc $out)"
  fi
}

test_default_run
test_editor_claude
test_editor_claude_without_native_does_not_write_vendor
test_editor_grok
test_mode_copy
test_lockstep_failures
test_lockstep_repo

echo "== native-first $PASS_COUNT passed, $FAIL_COUNT failed =="
[[ "$FAIL_COUNT" -eq 0 ]]
