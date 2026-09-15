"""Evaluate the frozen timing and RSS gates without claiming product adoption."""
import argparse
import hashlib
import json
import math
import statistics
from pathlib import Path


def distribution(values):
    ordered = sorted(values)
    return dict(median=statistics.median(values),
                p95=ordered[math.ceil(.95 * len(ordered)) - 1],
                maximum=max(values))


def analyze(source):
    rows = source['samples']
    result = dict(status='incomplete', groups=[], adoption='not_proven',
                  memory_method=source.get('memory_peak'),
                  required_additional_evidence=['matched APK size comparison',
                      'legacy and custom compatibility',
                      'fault, timeout, library and multi-engine lifecycle tests'])
    if source['status'] != 'passed' or source['rounds'] < 20 or source['batches'] < 2:
        return result
    expected_count = source['rounds'] * source['batches'] * 4
    identities = {(r['batch'], r['round'], r['tier'], r['mode']) for r in rows}
    if len(rows) != expected_count or len(identities) != expected_count:
        raise ValueError('Missing or duplicate samples')
    for batch in range(source['batches']):
        for tier in ['lean', 'whole']:
            group = dict(batch=batch, tier=tier)
            for mode in ['channel', 'ffi']:
                selected = [r for r in rows if (r['batch'], r['tier'], r['mode']) == (batch, tier, mode)]
                if {r['round'] for r in selected} != set(range(source['rounds'])):
                    raise ValueError('Incomplete paired group')
                group[mode] = dict(
                    bootstrap_us=distribution([r['timing']['total_us'] for r in selected]),
                    rss_high_water_kib=distribution([r['memory_kib']['VmHWM'] for r in selected]),
                    cpu_ticks=distribution([r['process_cpu_ticks'] for r in selected]),
                    android_total_ms=distribution([r['android_total_ms'] for r in selected]),
                    budget_pass_count=sum(r['timing']['total_us'] <= (85000 if tier == 'lean' else 200000) for r in selected))
            a, b = group['channel'], group['ffi']
            gain = a['bootstrap_us']['median'] - b['bootstrap_us']['median']
            relative = gain / a['bootstrap_us']['median']
            tail = b['bootstrap_us']['p95'] - a['bootstrap_us']['p95']
            # Compare the largest observed process high-water mark, not a snapshot or mean.
            memory_delta = b['rss_high_water_kib']['maximum'] - a['rss_high_water_kib']['maximum']
            memory_limit = max(4096, .05 * a['rss_high_water_kib']['maximum'])
            group.update(gain_us=gain, gain_fraction=relative, p95_increase_us=tail,
                         memory_increase_kib=memory_delta, memory_limit_kib=memory_limit,
                         timing_gate=gain >= 10000 and relative >= .1 and tail <= 5000,
                         memory_gate=memory_delta <= memory_limit)
            result['groups'].append(group)
    result['status'] = 'evaluated'
    result['timing_and_memory_gates_passed'] = all(g['timing_gate'] and g['memory_gate'] for g in result['groups'])
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--result', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    data = args.result.read_bytes()
    report = analyze(json.loads(data))
    report['source_sha256'] = hashlib.sha256(data).hexdigest()
    args.out.write_text(json.dumps(report, indent=2))
