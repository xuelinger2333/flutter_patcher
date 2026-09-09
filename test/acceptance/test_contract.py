import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest
import zipfile
import io

spec = importlib.util.spec_from_file_location('corpus', Path(__file__).with_name('corpus.py'))
corpus = importlib.util.module_from_spec(spec)
spec.loader.exec_module(corpus)


class CorpusContract(unittest.TestCase):
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
