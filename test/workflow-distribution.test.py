#!/usr/bin/env python3
"""Synthetic maintained distributor regression fixtures; no fleet installations."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

class Workflows(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='revcon-workflows-')
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name) / 'revcon'
        self.target = Path(self.temp.name) / 'target'
        self.repo.mkdir(); self.target.mkdir()
        for name in ('link.sh', 'status.sh', 'unlink.sh'):
            shutil.copy2(ROOT / name, self.repo / name)
        self.source = self.repo / 'profiles/one/workflows/WORKFLOWS.md'
        self.source.parent.mkdir(parents=True)
        self.source.write_text('shared one\n')
        self.env = dict(os.environ, REVCON_SKIP_EDITORS='', REVCON_PRIVATE_PROFILES_DIR='')

    def run_script(self, name, *args, ok=True):
        result = subprocess.run(['bash', str(self.repo / name), '--target', str(self.target), *args], env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode == 0, ok, result.stdout + result.stderr)
        return result

    def link(self, *args, ok=True):
        return self.run_script('link.sh', '--profile', 'one', *args, ok=ok)

    def test_all_adapters_symlink_status_idempotence_unlink(self):
        self.link('--editor','all','--mode','symlink')
        self.link('--editor','all','--mode','symlink')
        status = json.loads(self.run_script('status.sh', '--json').stdout)
        for editor in ('cursor', 'zed', 'vscode', 'claude', 'agents'):
            dst = self.target / f'.{editor}/workflows/WORKFLOWS.md'
            self.assertEqual(dst.resolve(), self.source)
            self.assertEqual(status['targets'][0]['editors'][editor]['files'][0]['source'], 'profiles/one/workflows/WORKFLOWS.md')
        self.run_script('unlink.sh')
        self.assertFalse((self.target / '.cursor/workflows/WORKFLOWS.md').exists())

    def test_copy_migration_manifests_status_gate_unlink(self):
        old = self.repo / 'profiles/one/cursor/workflows/WORKFLOWS.md'
        dst = self.target / '.cursor/workflows/WORKFLOWS.md'
        dst.parent.mkdir(parents=True); dst.write_text('old managed\n')
        manifest = dst.parents[1] / '.revcon-manifest.json'
        manifest.write_text(json.dumps({'mode':'copy','editor':'cursor','profiles':['one'],'files':{'workflows/WORKFLOWS.md':{'source':str(old.relative_to(self.repo)), 'sha256':hashlib.sha256(dst.read_bytes()).hexdigest()}}}))
        self.link('--editor','cursor','--mode','copy')
        before = manifest.read_bytes()
        self.link('--editor','cursor','--mode','copy')
        self.assertEqual(manifest.read_bytes(), before)
        self.assertEqual(json.loads(before)['files']['workflows/WORKFLOWS.md']['source'], 'profiles/one/workflows/WORKFLOWS.md')
        self.run_script('status.sh','--verify')
        gate = subprocess.run(['bash',str(ROOT/'scripts/verify-copy-lockstep.sh'),'--target',str(self.target),'--dot','.cursor'], capture_output=True,text=True)
        self.assertEqual(gate.returncode, 0, gate.stdout + gate.stderr)
        dst.write_text('user changes\n')
        self.link('--editor','cursor','--mode','copy',ok=False)
        self.run_script('unlink.sh','--editor','cursor')
        self.assertEqual(dst.read_text(),'user changes\n')

    def test_dangling_managed_symlink_migrates(self):
        dst = self.target / '.cursor/workflows/WORKFLOWS.md'
        dst.parent.mkdir(parents=True)
        dst.symlink_to(self.repo/'profiles/one/cursor/workflows/WORKFLOWS.md')
        self.link('--editor','cursor','--mode','symlink')
        self.assertEqual(dst.resolve(),self.source)

    def test_layers_and_skip(self):
        base = self.repo/'base/cursor/workflows/WORKFLOWS.md'
        base.parent.mkdir(parents=True); base.write_text('base')
        self.link('--editor','cursor','--mode','symlink')
        self.assertEqual((self.target/'.cursor/workflows/WORKFLOWS.md').resolve(),self.source)
        overlay = self.repo/'profiles/one/cursor/workflows/WORKFLOWS.md'
        overlay.parent.mkdir(parents=True); overlay.write_text('adapter overlay')
        self.link('--editor','all','--skip','zed','--mode','symlink')
        self.assertEqual((self.target/'.cursor/workflows/WORKFLOWS.md').resolve(),overlay)
        self.assertFalse((self.target/'.zed').exists())
        later = self.repo/'profiles/two/workflows/WORKFLOWS.md'
        later.parent.mkdir(parents=True); later.write_text('later shared')
        self.link('--profile','two','--editor','cursor','--mode','symlink')
        self.assertEqual((self.target/'.cursor/workflows/WORKFLOWS.md').resolve(),later)

    def test_user_files_and_external_symlinks_preserved(self):
        dst = self.target/'.cursor/workflows/WORKFLOWS.md'
        dst.parent.mkdir(parents=True); dst.write_text('user')
        self.link('--editor','cursor','--mode','copy',ok=False)
        self.assertEqual(dst.read_text(),'user')
        dst.unlink(); external = Path(self.temp.name)/'external'; external.write_text('external')
        dst.symlink_to(external)
        self.link('--editor','cursor',ok=False)
        self.assertEqual(dst.resolve(),external)

    def test_missing_source_and_parent_escape_fail(self):
        self.source.unlink(); self.source.symlink_to('missing.md')
        self.link('--editor','cursor',ok=False)
        self.source.unlink(); self.source.write_text('shared')
        outside = Path(self.temp.name)/'outside'; outside.mkdir()
        parent = self.target/'.cursor/workflows'; parent.parent.mkdir(exist_ok=True); parent.symlink_to(outside)
        self.link('--editor','cursor',ok=False)
        self.assertFalse((outside/'WORKFLOWS.md').exists())

    def test_structured_manifest_filename_bytes_and_control_rejection(self):
        name = 'with spaces "quotes" and \\slash.md'
        extra = self.source.parent / name
        extra.write_text('safe bytes')
        self.link('--editor','cursor','--mode','copy')
        manifest = json.loads((self.target/'.cursor/.revcon-manifest.json').read_text())
        self.assertIn('workflows/' + name, manifest['files'])
        self.assertEqual((self.target/'.cursor/workflows'/name).read_text(),'safe bytes')
        (self.source.parent/'bad\nname.md').write_text('bad')
        self.link('--editor','cursor','--mode','copy',ok=False)
        self.assertFalse((self.target/'.cursor/workflows/bad\nname.md').exists())

    def test_symlink_root_and_traversal_ownership(self):
        self.source.unlink(); self.source.parent.rmdir()
        self.source.parent.symlink_to(Path(self.temp.name)/'absent')
        self.link('--editor','cursor',ok=False)
        self.source.parent.unlink(); self.source.parent.mkdir(); self.source.write_text('shared')
        outside = Path(self.temp.name)/'outside.md'; outside.write_text('foreign')
        dst = self.target/'.cursor/workflows/WORKFLOWS.md'
        dst.parent.mkdir(parents=True)
        dst.symlink_to(str(self.repo)+'/../outside.md')
        self.link('--editor','cursor',ok=False)
        self.assertEqual(dst.resolve(),outside)

    def test_all_adapters_copy_gate_and_unlink(self):
        self.link('--editor','all','--mode','copy')
        for editor in ('cursor','zed','vscode','claude','agents'):
            dst = self.target/f'.{editor}/workflows/WORKFLOWS.md'
            self.assertFalse(dst.is_symlink())
            self.assertEqual(dst.read_bytes(),self.source.read_bytes())
            gate = subprocess.run(['bash',str(ROOT/'scripts/verify-copy-lockstep.sh'),'--target',str(self.target),'--dot',f'.{editor}'], capture_output=True,text=True)
            self.assertEqual(gate.returncode,0,gate.stdout+gate.stderr)
        self.run_script('status.sh','--verify')
        self.run_script('unlink.sh')
        for editor in ('cursor','zed','vscode','claude','agents'):
            self.assertFalse((self.target/f'.{editor}/workflows/WORKFLOWS.md').exists())

    def test_dry_run_does_not_materialize_workflows(self):
        self.link('--editor','all','--mode','copy','--dry-run')
        self.assertEqual(list(self.target.iterdir()),[])

if __name__ == '__main__':
    unittest.main()
