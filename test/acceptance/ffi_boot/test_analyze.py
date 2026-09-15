import copy
import unittest
from analyze import analyze


def fixture():
    rows = []
    for batch in range(2):
        for index in range(20):
            for tier in ['lean', 'whole']:
                for mode in ['channel', 'ffi']:
                    rows.append(dict(batch=batch, round=index, tier=tier, mode=mode,
                        timing={'total_us': 80000 if mode == 'channel' else 60000},
                        memory_kib={'VmHWM': 200000}, process_cpu_ticks=50,
                        android_total_ms=200))
    return dict(status='passed', rounds=20, batches=2, samples=rows)


class Gates(unittest.TestCase):
    def test_pass_never_means_adopt(self):
        result = analyze(fixture())
        self.assertTrue(result['timing_and_memory_gates_passed'])
        self.assertEqual(result['adoption'], 'not_proven')

    def test_incomplete_never_passes(self):
        data = fixture()
        data['status'] = 'failed'
        self.assertEqual(analyze(data)['status'], 'incomplete')

    def test_duplicate_pair_rejected(self):
        data = fixture()
        data['samples'][-1] = copy.deepcopy(data['samples'][0])
        with self.assertRaises(ValueError):
            analyze(data)

    def test_tail_and_peak_cannot_hide_in_medians(self):
        data = fixture()
        selected = [r for r in data['samples'] if r['mode'] == 'ffi' and r['batch'] == 0 and r['tier'] == 'lean']
        for row in selected[-2:]:
            row['timing']['total_us'] = 100000
        selected[0]['memory_kib']['VmHWM'] = 220000
        group = analyze(data)['groups'][0]
        self.assertFalse(group['timing_gate'])
        self.assertFalse(group['memory_gate'])


if __name__ == '__main__':
    unittest.main()
