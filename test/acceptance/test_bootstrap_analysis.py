import json
from pathlib import Path
import tempfile
import unittest
from analyze_bootstrap import analyze, details


class BootstrapBudgetTest(unittest.TestCase):
    def test_native_bytes_profiles_remove_only_redundant_work(self):
        detail = dict(schema=2, transport='native-bytes-v1',
            native=dict(total=10, prepare=1, read=2, envelope_verify=3, file_digest=4),
            verify=dict(envelope_fields_us=1, zip_total_us=4, zip_crc_us=3,
                        manifest_and_entries_us=5, entry_sha256_us=4),
            mark_booting_us=2, observe_us=1, module_load_us=7)
        row = dict(payload_us=20, verify_us=10, load_and_handshake_us=10,
                   resources_us=1, total_us=41)
        buckets = details(row, detail)
        self.assertEqual(sum(buckets.values()), 41)
        self.assertEqual(buckets['dart_file_sha256'], 0)
        self.assertEqual(buckets['dart_payload_sha256'], 0)
        self.assertEqual(buckets['dart_entry_sha256'], 4)
        detail['verify']['payload_sha256_us'] = 0
        with self.assertRaises(ValueError): details(row, detail)
        del detail['verify']['payload_sha256_us']
        del detail['verify']['entry_sha256_us']
        with self.assertRaises(KeyError): details(row, detail)

    def test_each_tier_uses_absolute_bootstrap_budget_with_inclusive_boundary(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            matrix = root / 'matrix'; matrix.mkdir()
            (root / 'source.json').write_text(json.dumps({'source_sha256': 'fixture'}))
            (matrix / 'live-logcat.txt').write_text('')
            def write(tier, total):
                sample = dict(payload_us=total, verify_us=0, load_and_handshake_us=0,
                              resources_us=0, total_us=total)
                (matrix / ('valid-' + tier + '-timing.json')).write_text(json.dumps(
                    {'bootstrap': [sample] * 10, 'median': 900, 'original': {'median': 1}}))
            write('lean', 85000); write('whole', 200000)
            self.assertTrue(all(t['budget_passed'] for t in analyze(root)['tiers'].values()))
            write('lean', 85001)
            result = analyze(root)['tiers']
            self.assertFalse(result['lean']['budget_passed'])
            self.assertTrue(result['whole']['budget_passed'])
            write('whole', 200001)
            self.assertFalse(analyze(root)['tiers']['whole']['budget_passed'])


if __name__ == '__main__':
    unittest.main()
