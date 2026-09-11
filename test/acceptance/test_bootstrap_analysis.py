import json
from pathlib import Path
import tempfile
import unittest
from analyze_bootstrap import analyze


class BootstrapBudgetTest(unittest.TestCase):
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
