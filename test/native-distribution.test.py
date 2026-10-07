"""Portable native skill delivery and single-owner regression fixtures."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class NativeDelivery(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="revcon-native-")
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name) / "revcon"
        self.target = Path(self.temp.name) / "target"
        self.repo.mkdir()
        self.target.mkdir()
        shutil.copy2(ROOT / "link.sh", self.repo / "link.sh")
        self.source = self.repo / "profiles/revealui/agents/skills/profile-only/SKILL.md"
        self.source.parent.mkdir(parents=True)
        self.source.write_text("profile guidance\n")
        self.destination = self.target / ".agents/skills/profile-only/SKILL.md"
        self.env = dict(os.environ, REVCON_SKIP_EDITORS="", REVCON_PRIVATE_PROFILES_DIR="")

    def link(self, *args, ok=True):
        result = subprocess.run(
            ["bash", str(self.repo / "link.sh"), "--target", str(self.target),
             "--editor", "agents", "--profile", "revealui", *args],
            env=self.env, capture_output=True, text=True,
        )
        self.assertEqual(result.returncode == 0, ok, result.stdout + result.stderr)
        return result

    def test_default_delivery_and_reapply_are_portable_copies(self):
        self.link()
        self.assertFalse(self.destination.is_symlink())
        manifest = self.target / ".agents/.revcon-manifest.json"
        original = manifest.read_bytes()
        self.link()
        self.assertEqual(manifest.read_bytes(), original)
        self.source.write_text("updated canonical guidance\n")
        self.link()
        self.assertEqual(self.destination.read_text(), self.source.read_text())

    def test_migrates_dangling_profile_link_after_checkout_relocation(self):
        self.destination.parent.mkdir(parents=True)
        self.destination.symlink_to("/retired/revcon/profiles/revealui/agents/skills/profile-only/SKILL.md")
        self.link()
        self.assertFalse(self.destination.is_symlink())

    def test_foreign_links_and_owner_modifications_are_preserved(self):
        self.destination.parent.mkdir(parents=True)
        self.destination.symlink_to("/foreign/SKILL.md")
        self.link(ok=False)
        self.assertTrue(self.destination.is_symlink())
        self.destination.unlink()
        self.link()
        self.destination.write_text("owner changes")
        self.link(ok=False)
        self.assertEqual(self.destination.read_text(), "owner changes")

    def test_rejects_symlinked_parent(self):
        outside = Path(self.temp.name) / "outside"
        outside.mkdir()
        (self.target / ".agents").symlink_to(outside)
        self.link(ok=False)
        self.assertEqual(list(outside.iterdir()), [])

    def test_harness_owned_files_have_one_owner_and_are_preserved(self):
        name = "revealui-safety"
        source = self.source.parent.parent / name / "SKILL.md"
        source.parent.mkdir()
        source.write_text("legacy profile body")
        destination = self.target / f".agents/skills/{name}/SKILL.md"
        destination.parent.mkdir(parents=True)
        destination.write_text("canonical harness body")
        ledger = self.target / ".revealui/adapters/codex-files.json"
        ledger.parent.mkdir(parents=True)
        ledger.write_text(json.dumps({"version": 1, "files": {
            f".agents/skills/{name}/SKILL.md": hashlib.sha256(destination.read_bytes()).hexdigest()
        }}))
        self.link()
        self.assertEqual(destination.read_text(), "canonical harness body")
        manifest = json.loads((self.target / ".agents/.revcon-manifest.json").read_text())
        self.assertNotIn(f"skills/{name}/SKILL.md", manifest["files"])
        gate = subprocess.run(["bash", str(ROOT / "scripts/verify-copy-lockstep.sh"),
                               "--target", str(self.target), "--dot", ".agents"], capture_output=True, text=True)
        self.assertEqual(gate.returncode, 0, gate.stdout + gate.stderr)
        destination.write_text("modified owner content")
        self.link(ok=False)
        self.assertEqual(destination.read_text(), "modified owner content")


class ClaudeOwnership(unittest.TestCase):
    def setUp(self):
        NativeDelivery.setUp(self)
        self.source = self.repo / "profiles/revealui/claude/rules/biome.md"
        self.source.parent.mkdir(parents=True)
        self.source.write_text("legacy profile body")
        native = self.repo / "profiles/revealui/revealui/rules/biome.md"
        native.parent.mkdir(parents=True)
        native.write_text("native profile body")
        self.destination = self.target / ".claude/rules/biome.md"
        self.destination.parent.mkdir(parents=True)
        self.destination.write_text("canonical harness body")
        self.content = self.target / ".revealui/custom/rules/biome.md"
        self.content.parent.mkdir(parents=True)
        self.content.write_text("canonical harness body")
        (self.target / ".revealui/manager.json").write_text(json.dumps({"contentRoot": "custom"}))
        self.ledger = self.target / ".claude/.revcon-manifest.json"
        self.ledger.write_text(json.dumps({"mode": "copy", "editor": "claude", "profiles": ["revealui"], "files": {
            "rules/biome.md": {"source": "harnesses:rules/biome.md", "sha256": hashlib.sha256(self.destination.read_bytes()).hexdigest()}
        }}))

    def link(self, *args, ok=True):
        return NativeDelivery.link(self, "--editor", "claude", *args, ok=ok)

    def test_preserves_manager_pointer_and_validates_its_canonical_owner(self):
        rel = "rules/00-revealui-manager.md"
        pointer = self.target / ".claude" / rel
        canonical = self.target / ".revealui/adapters/claude-code.md"
        canonical.parent.mkdir(parents=True)
        body = "# Canonical manager pointer\n"
        pointer.write_text(body)
        canonical.write_text(body)
        ledger = json.loads(self.ledger.read_text())
        ledger["files"][rel] = {"source": "harnesses:adapters/claude-code.md", "sha256": hashlib.sha256(body.encode()).hexdigest()}
        self.ledger.write_text(json.dumps(ledger))
        profile = self.repo / "profiles/revealui/revealui/rules/00-revealui-manager.md"
        profile.parent.mkdir(parents=True, exist_ok=True)
        profile.write_text("profile collision")
        self.link()
        self.assertEqual(pointer.read_text(), body)
        self.assertEqual(json.loads(self.ledger.read_text())["files"][rel]["source"], "harnesses:adapters/claude-code.md")
        gate = ["bash", str(ROOT / "scripts/verify-copy-lockstep.sh"), "--target", str(self.target)]
        self.assertEqual(subprocess.run(gate, capture_output=True).returncode, 0)
        canonical.write_text("edited canonical source")
        self.assertNotEqual(subprocess.run(gate, capture_output=True).returncode, 0)
        self.link(ok=False)
        self.assertEqual(pointer.read_text(), body)

    def test_preserves_canonical_owner_and_ledger_on_profile_reapply(self):
        self.link()
        self.assertEqual(self.destination.read_text(), "canonical harness body")
        self.assertEqual(self.content.read_text(), "canonical harness body")
        native_ledger = self.target / ".revealui/.revcon-manifest.json"
        if native_ledger.exists():
            self.assertNotIn("content/rules/biome.md", json.loads(native_ledger.read_text())["files"])
        manifest = json.loads(self.ledger.read_text())
        self.assertEqual(manifest["files"]["rules/biome.md"]["source"], "harnesses:rules/biome.md")
        first = self.ledger.read_bytes()
        self.source.write_text("new profile body")
        self.link()
        self.assertEqual(self.ledger.read_bytes(), first)
        gate = subprocess.run(["bash", str(ROOT / "scripts/verify-copy-lockstep.sh"), "--target", str(self.target)], capture_output=True, text=True)
        self.assertEqual(gate.returncode, 0, gate.stdout + gate.stderr)
        self.content.write_text("stale manager content")
        gate = subprocess.run(["bash", str(ROOT / "scripts/verify-copy-lockstep.sh"), "--target", str(self.target)], capture_output=True, text=True)
        self.assertNotEqual(gate.returncode, 0)

    def seed_legacy_projection(self):
        rel = "rules/tool-routing.md"
        native = self.repo / f"profiles/revealui/revealui/{rel}"
        native.write_text("native routing body")
        destination = self.target / f".claude/{rel}"
        destination.write_text("old managed routing body")
        manifest = json.loads(self.ledger.read_text())
        manifest["files"][rel] = {"source": f"profiles/revealui/claude/{rel}",
                                  "sha256": hashlib.sha256(destination.read_bytes()).hexdigest()}
        self.ledger.write_text(json.dumps(manifest))
        return destination

    def test_migrates_hash_verified_vendor_copy_to_native_projection(self):
        destination = self.seed_legacy_projection()
        self.link()
        self.assertEqual(destination.read_text(), "<!-- generated from .revealui/content/rules/tool-routing.md -->\n" + "native routing body")
        entry = json.loads(self.ledger.read_text())["files"]["rules/tool-routing.md"]
        self.assertEqual(entry["generatedFrom"], ".revealui/content/rules/tool-routing.md")
        first = self.ledger.read_bytes()
        self.link()
        self.assertEqual(self.ledger.read_bytes(), first)

    def test_modified_legacy_copy_blocks_migration_before_native_writes(self):
        destination = self.seed_legacy_projection()
        destination.write_text("owner pending edits")
        before = self.ledger.read_bytes()
        self.link(ok=False)
        self.assertEqual(destination.read_text(), "owner pending edits")
        self.assertEqual(self.ledger.read_bytes(), before)
        self.assertFalse((self.target / ".revealui/content/rules/tool-routing.md").exists())

    def test_unlink_preserves_harness_owner_and_prunes_removed_profile_entries(self):
        extra = self.source.parent / "profile-only.md"
        extra.write_text("profile output")
        self.link()
        result = subprocess.run(["bash", str(ROOT / "unlink.sh"), "--target", str(self.target), "--editor", "claude"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.destination.read_text(), "canonical harness body")
        self.assertFalse((self.destination.parent / extra.name).exists())
        self.assertEqual(set(json.loads(self.ledger.read_text())["files"]), {"rules/biome.md"})
        gate = subprocess.run(["bash", str(ROOT / "scripts/verify-copy-lockstep.sh"), "--target", str(self.target)], capture_output=True, text=True)
        self.assertEqual(gate.returncode, 0, gate.stdout + gate.stderr)

    def test_modified_harness_file_fails_before_profile_writes(self):
        extra = self.source.parent / "profile-only.md"
        extra.write_text("profile output")
        self.destination.write_text("owner pending edits")
        before = self.ledger.read_bytes()
        self.link(ok=False)
        self.assertEqual(self.destination.read_text(), "owner pending edits")
        self.assertEqual(self.ledger.read_bytes(), before)
        self.assertFalse((self.destination.parent / extra.name).exists())


class ProjectionRecovery(unittest.TestCase):
    def link(self, *args, ok=True):
        return ClaudeOwnership.link(self, *args, ok=ok)

    def setUp(self):
        ClaudeOwnership.setUp(self)
        self.rel = "skills/reference/references/example.ts"
        self.original = 'const color = "blue"\n'
        self.formatted = "const color = 'blue';\n"
        self.native = self.repo / "profiles/revealui/revealui" / self.rel
        self.native.parent.mkdir(parents=True)
        self.native.write_text(self.original)
        self.copy = self.target / ".grok" / self.rel
        self.copy.parent.mkdir(parents=True)
        self.copy.write_text(self.formatted)
        self.projection_ledger = self.target / ".grok/.revcon-manifest.json"
        self.entry = {"source": "profiles/revealui/revealui/" + self.rel,
                      "sha256": hashlib.sha256(self.original.encode()).hexdigest(),
                      "generatedFrom": ".revealui/content/" + self.rel}
        self.projection_ledger.write_text(json.dumps({"mode": "copy", "editor": "grok", "files": {self.rel: self.entry}}))
        subprocess.run(["git", "init", "-q", str(self.target)], check=True)
        subprocess.run(["git", "-C", str(self.target), "add", ".grok/.revcon-manifest.json"], check=True)
        subprocess.run(["git", "-C", str(self.target), "-c", "user.name=Fixture", "-c", "user.email=fixture@example.test", "commit", "-qm", "Record original ownership"], check=True)
        self.formatter = self.target / "node_modules/.bin/biome"
        self.formatter.parent.mkdir(parents=True)
        self.formatter.write_text("#!/usr/bin/env python3\nimport sys\nif sys.argv[1:] == ['--version']:\n print('Version: 2.5.2')\nelse:\n assert sys.argv[1:] == ['format', '--stdin-file-path=example.ts']\n assert sys.stdin.read() == " + repr(self.original) + "\n sys.stdout.write(" + repr(self.formatted) + ")\n")
        self.formatter.chmod(0o755)

    def test_recovers_only_reproducible_formatter_output_and_is_idempotent(self):
        before = self.projection_ledger.read_bytes()
        self.link(ok=False)
        self.assertEqual(self.projection_ledger.read_bytes(), before)
        result = self.link("--recover-formatting")
        self.assertIn("[recover-formatting]", result.stdout)
        self.assertEqual(self.copy.read_text(), self.original)
        first = self.projection_ledger.read_bytes()
        self.link("--recover-formatting")
        self.assertEqual(self.projection_ledger.read_bytes(), first)

    def test_current_approved_formatter_release_uses_the_same_proof_contract(self):
        self.formatter.write_text(self.formatter.read_text().replace('Version: 2.5.2', 'Version: 2.5.4'))
        self.link("--recover-formatting")
        self.assertEqual(self.copy.read_text(), self.original)

    def test_dry_run_proves_recovery_without_changing_any_target_bytes(self):
        before = self.projection_ledger.read_bytes()
        self.link("--recover-formatting", "--dry-run")
        self.assertEqual(self.copy.read_text(), self.formatted)
        self.assertEqual(self.projection_ledger.read_bytes(), before)
        self.assertFalse((self.target / ".revealui/content" / self.rel).exists())

    def test_genuine_edits_fail_before_native_or_ledger_writes(self):
        self.copy.write_text("const color = 'red';\n")
        before = self.projection_ledger.read_bytes()
        self.link("--recover-formatting", ok=False)
        self.assertEqual(self.copy.read_text(), "const color = 'red';\n")
        self.assertEqual(self.projection_ledger.read_bytes(), before)
        self.assertFalse((self.target / ".revealui/content" / self.rel).exists())

    def test_changed_source_and_untrusted_ledger_cannot_authorize_recovery(self):
        self.native.write_text("const color = 'red';\n")
        self.link("--recover-formatting", ok=False)
        self.native.write_text(self.original)
        ledger = json.loads(self.projection_ledger.read_text())
        ledger["files"][self.rel]["generatedFrom"] = ".revealui/content/skills/foreign.ts"
        self.projection_ledger.write_text(json.dumps(ledger))
        self.link("--recover-formatting", ok=False)
        self.assertEqual(self.copy.read_text(), self.formatted)
        self.assertFalse((self.target / ".revealui/content" / self.rel).exists())

    def test_missing_or_wrong_formatter_version_fails_without_writes(self):
        self.formatter.unlink()
        self.link("--recover-formatting", ok=False)
        self.formatter.write_text("#!/bin/sh\nprintf 'Version: 9.0.0\\n'\n")
        self.formatter.chmod(0o755)
        self.link("--recover-formatting", ok=False)
        self.assertEqual(self.copy.read_text(), self.formatted)




if __name__ == "__main__":
    unittest.main()
