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

    def test_preserves_canonical_owner_and_ledger_on_profile_reapply(self):
        self.link()
        self.assertEqual(self.destination.read_text(), "canonical harness body")
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



if __name__ == "__main__":
    unittest.main()
