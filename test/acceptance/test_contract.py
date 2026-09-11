import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest
import zipfile
import io
import json
import hashlib
import subprocess
import tarfile
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('corpus', Path(__file__).with_name('corpus.py'))
corpus = importlib.util.module_from_spec(spec)
spec.loader.exec_module(corpus)


class CorpusContract(unittest.TestCase):
    def test_resume_rejects_changed_build_config_before_any_device_or_ssh_call(self):
        module_spec = importlib.util.spec_from_file_location('rebuild', Path(__file__).with_name('rebuild_regression.py'))
        rebuild = importlib.util.module_from_spec(module_spec)
        module_spec.loader.exec_module(rebuild)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            prior = root / 'prior'; prior.mkdir()
            (prior / 'config.json').write_text(json.dumps({'binding': 'custom'}))
            config = root / 'config.json'
            config.write_text(json.dumps({'binding': 'standard', 'ssh_host': 'test-builder',
                                          'remote_root': '/tmp/regression-tests'}))
            output = root / 'output'
            with patch('sys.argv', ['rebuild', '--config', str(config), '--out', str(output),
                                     '--resume-built', str(prior)]), patch.object(rebuild.subprocess, 'run') as external:
                with self.assertRaisesRegex(ValueError, 'configuration differs: binding'):
                    rebuild.main()
                external.assert_not_called()
            result = json.loads((output / 'result.json').read_text())
            self.assertEqual(result['status'], 'failed')
            self.assertIn('configuration differs', result['error'])

    def test_rebuild_snapshot_uses_working_bytes_and_excludes_ignored_files(self):
        module_spec = importlib.util.spec_from_file_location('rebuild', Path(__file__).with_name('rebuild_regression.py'))
        rebuild = importlib.util.module_from_spec(module_spec)
        module_spec.loader.exec_module(rebuild)
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory) / 'repo'; repo.mkdir()
            out = Path(directory) / 'out'; out.mkdir()
            def git(*args):
                subprocess.run(['git', '-C', str(repo), *args], check=True, capture_output=True)
            git('init')
            (repo / '.gitignore').write_text('secret.txt\n')
            (repo / 'changed.kt').write_text('old')
            (repo / 'deleted.kt').write_text('deleted')
            git('add', '.')
            git('-c', 'user.name=Snapshot Test', '-c', 'user.email=test@example.invalid', 'commit', '-m', 'fixture')
            (repo / 'changed.kt').write_text('new verifier')
            (repo / 'deleted.kt').unlink()
            (repo / 'new.kt').write_text('new untracked source')
            (repo / 'secret.txt').write_text('must stay local')
            receipt = rebuild.snapshot(repo.resolve(), out)
            self.assertNotIn('deleted.kt', receipt['files'])
            self.assertNotIn('secret.txt', receipt['files'])
            self.assertIn('new.kt', receipt['files'])
            with tarfile.open(out / 'source.tar.gz') as archive:
                self.assertEqual(archive.extractfile('source/changed.kt').read(), b'new verifier')
                for name, digest in receipt['files'].items():
                    self.assertEqual(hashlib.sha256(archive.extractfile('source/' + name).read()).hexdigest(), digest)
            self.assertEqual(receipt['source_sha256'], hashlib.sha256(json.dumps(receipt['files'], sort_keys=True).encode()).hexdigest())

    def test_stored_records_have_no_extras_and_are_deterministic(self):
        data = corpus.stored([('module.bc', b'abc'), ('patch_manifest.json', b'{}')])
        self.assertEqual(data, corpus.stored([('module.bc', b'abc'), ('patch_manifest.json', b'{}')]))
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            for row in archive.infolist():
                self.assertEqual(row.compress_type, zipfile.ZIP_STORED)
                self.assertEqual(row.extra, b'')
                self.assertEqual(row.flag_bits & 8, 0)

    def test_device_and_cross_machine_requirements_fail_closed(self):
        device_spec = importlib.util.spec_from_file_location('device', Path(__file__).with_name('device.py'))
        device = importlib.util.module_from_spec(device_spec)
        device_spec.loader.exec_module(device)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            apk = root / 'fixture.apk'
            apk.write_bytes(b'not-an-apk')
            with self.assertRaises(ValueError):
                device.run(apk, root, 'no-device', 'com.user.real_app', root / 'result')
            self.assertIn('"status": "failed"', (root / 'result/device.json').read_text())


if __name__ == '__main__':
    unittest.main()
