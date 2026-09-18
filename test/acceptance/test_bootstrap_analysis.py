import json
from pathlib import Path
import tempfile
import unittest
from analyze_bootstrap import analyze, details


class BootstrapBudgetTest(unittest.TestCase):
    def test_ffi_profile_does_not_require_a_java_boot_channel_trace(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            matrix = root / 'matrix'; matrix.mkdir()
            (root / 'source.json').write_text(json.dumps({'source_sha256': 'fixture'}))
            logs = []
            for tier in ['lean', 'whole']:
                rows = []
                for i in range(10):
                    row = dict(payload_us=20+i, verify_us=10, load_and_handshake_us=10,
                               resources_us=1, total_us=41+i)
                    rows.append(row)
                    detail = dict(schema=2, transport='native-bytes-v1', tier=tier,
                        native=dict(total=10, prepare=1, read=2, envelope_verify=3, file_digest=4),
                        verify=dict(envelope_fields_us=1, zip_total_us=4, zip_crc_us=3,
                                    manifest_and_entries_us=5, entry_sha256_us=4),
                        mark_booting_us=2, observe_us=1, module_load_us=7,
                        dart_channel={'total': 20+i, 'ffi': 1})
                    prefix = f'{100+i}.000 123 123 I flutter : '
                    logs.append(prefix + 'BYTECODE_BOOT_TIMING: ' + ' '.join(f'{k}={v}' for k,v in row.items()))
                    logs.append(prefix + 'BYTECODE_BOOT_PROFILE: ' + json.dumps(detail))
                (matrix / f'valid-{tier}-timing.json').write_text(json.dumps(
                    {'bootstrap': rows, 'median': 90, 'original': {'median': 80}}))
            # init() still calls markBooting on MethodChannel after patched main.
            trace = dict(schema=2, method='markBooting', **{k:0 for k in [
                'decode_us','handler_us','worker_queue_us','operation_us','main_queue_us',
                'encode_us','reply_send_us','total_us']})
            logs.append('200.000 123 123 I flutter : BYTECODE_CHANNEL_TIMING: ' + json.dumps(trace))
            (matrix / 'live-logcat.txt').write_text('\n'.join(logs))
            result = analyze(root)
            for tier in result['tiers'].values():
                self.assertEqual(len(tier['profiles']), 10)
                self.assertNotIn('outside_java_channel', tier)

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
            write('lean', 85000); write('whole', 250000)
            self.assertTrue(all(t['budget_passed'] for t in analyze(root)['tiers'].values()))
            write('lean', 85001)
            result = analyze(root)['tiers']
            self.assertFalse(result['lean']['budget_passed'])
            self.assertTrue(result['whole']['budget_passed'])
            write('whole', 250001)
            self.assertFalse(analyze(root)['tiers']['whole']['budget_passed'])
            # A custom-binding "lean" control can actually be whole.
            write('lean', 190000)
            path = matrix / 'valid-lean-timing.json'
            custom = json.loads(path.read_text())
            custom['bootstrap_budget_us'] = 250000
            path.write_text(json.dumps(custom))
            item = analyze(root)['tiers']['lean']
            self.assertEqual(item['actual_tier'], 'whole')
            self.assertTrue(item['budget_passed'])


if __name__ == '__main__':
    unittest.main()
