"""Summarize exact cold-start samples; nested profile counters are not additive.

python test/acceptance/analyze_bootstrap.py --run PATH --out PATH/report.json
Add --assert-budget to enforce lean 85 ms and whole 200 ms per sampled startup.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import statistics


STAGES = ['payload_us', 'verify_us', 'load_and_handshake_us', 'resources_us', 'total_us']
BUDGET_US = {'lean': 85000, 'whole': 200000}
TIMING = re.compile(r'BYTECODE_BOOT_TIMING: ' + r' '.join(k + r'=(\d+)' for k in STAGES))


def stats(values):
    return dict(mean_ms=statistics.mean(values) / 1000,
                median_ms=statistics.median(values) / 1000,
                min_ms=min(values) / 1000, max_ms=max(values) / 1000)


def details(row, detail):
    native, verify = detail['native'], detail['verify']
    direct = detail['schema'] == 2
    if direct and (detail.get('transport') != 'native-bytes-v1' or
                   any(k in detail for k in ['read_file_us']) or
                   any(k in verify for k in ['payload_sha256_us', 'file_sha256_us'])):
        raise ValueError('Invalid native-bytes profile')
    buckets = {
        'channel_and_dispatch': row['payload_us'] - native['total'],
        'native_prepare': native['prepare'],
        'native_read': native['read'],
        'native_envelope_verify': native['envelope_verify'],
        'native_file_digest': native['file_digest'],
        'native_other': native['total'] - sum(native[k] for k in
            ['prepare', 'read', 'envelope_verify', 'file_digest']),
        'dart_read_file': (0 if direct else detail['read_file_us']),
        'dart_envelope_fields': verify['envelope_fields_us'],
        'dart_payload_sha256': (0 if direct else verify['payload_sha256_us']),
        'dart_file_sha256': (0 if direct else verify['file_sha256_us']),
        'dart_zip_crc': verify['zip_crc_us'],
        'dart_zip_structure': verify['zip_total_us'] - verify['zip_crc_us'],
        'dart_entry_sha256': verify['entry_sha256_us'],
        'dart_manifest_other': verify['manifest_and_entries_us'] - verify['entry_sha256_us'],
        'mark_booting': detail['mark_booting_us'],
        'observe': detail['observe_us'],
        'module_load': detail['module_load_us'],
        'resources': row['resources_us'],
    }
    buckets['dart_verify_other'] = row['verify_us'] - (0 if direct else detail['read_file_us']) - sum(
        verify[k] for k in (['envelope_fields_us', 'zip_total_us', 'manifest_and_entries_us'] if direct else
            ['envelope_fields_us', 'payload_sha256_us', 'file_sha256_us', 'zip_total_us', 'manifest_and_entries_us']))
    if min(buckets.values()) < 0 or sum(buckets.values()) != row['total_us']:
        raise ValueError('Detailed counters do not reconcile with total')
    return buckets


def analyze(run):
    matrix = run / 'matrix'
    raw_log = (matrix / 'live-logcat.txt').read_bytes()
    text = raw_log.decode('utf-8')
    pending, records, channels = {}, [], []
    for line in text.splitlines():
        fields = line.split()
        if len(fields) < 3 or not re.match(r'^\d+\.\d+$', fields[0]):
            continue
        pid = fields[1]
        channel_prefix = 'BYTECODE_CHANNEL_TIMING: '
        if channel_prefix in line:
            channel = json.loads(line.split(channel_prefix, 1)[1])
            parts = ['decode_us', 'handler_us', 'worker_queue_us', 'operation_us',
                     'main_queue_us', 'encode_us', 'reply_send_us']
            if channel['schema'] not in [1, 2] or min(channel[k] for k in parts) < 0 or sum(channel[k] for k in parts) != channel['total_us']:
                raise ValueError('Native channel counters do not reconcile')
            channels.append((float(fields[0]), pid, channel))
        match = TIMING.search(line)
        if match:
            pending[pid] = tuple(map(int, match.groups()))
        prefix = 'BYTECODE_BOOT_PROFILE: '
        if prefix in line:
            if pid not in pending:
                raise ValueError('Profile without matching preceding timing')
            detail = json.loads(line.split(prefix, 1)[1])
            if detail['schema'] not in [1, 2]:
                raise ValueError('Unknown profile schema')
            records.append((pending.pop(pid), detail, pid, float(fields[0])))
    report = {'source': json.loads((run / 'source.json').read_text())['source_sha256'],
              'log_sha256': hashlib.sha256(raw_log).hexdigest(), 'tiers': {}}
    for tier in ['lean', 'whole']:
        timing = json.loads((matrix / ('valid-' + tier + '-timing.json')).read_text())
        rows = timing['bootstrap']
        if len(rows) != 10 or any(sum(r[k] for k in STAGES[:4]) != r['total_us'] for r in rows):
            raise ValueError('Expected ten complete reconciled cold-start samples')
        total = statistics.mean(r['total_us'] for r in rows)
        item = {'samples': len(rows), 'android_total_time_median_ms': timing['median'],
                'original_total_time_median_ms': timing['original']['median'],
                'stages': {k: dict(stats([r[k] for r in rows]),
                                  percent_of_total=statistics.mean(r[k] for r in rows) / total * 100)
                           for k in STAGES},
                'budget_us': BUDGET_US[tier],
                'budget_policy': 'lean-85ms-whole-200ms-v1',
                'budget_passed': all(r['total_us'] <= BUDGET_US[tier] for r in rows)}
        profiles = []
        if records:
            for row in rows:
                matches = [(d, pid, timestamp) for key, d, pid, timestamp in records
                           if key == tuple(row[k] for k in STAGES) and d['tier'] == tier]
                if len(matches) != 1:
                    raise ValueError('Expected exactly one profile per measured cold start')
                d, pid, timestamp = matches[0]
                if 'budget_us' in d and d['budget_us'] != BUDGET_US[tier]:
                    raise ValueError('Application budget differs from analysis policy')
                sample = {'pid': pid, 'buckets_us': details(row, d), 'raw': d}
                if channels:
                    matched = [ch for at, cp, ch in channels if cp == pid and abs(at - timestamp) < 3
                               and ch.get('method', 'bootPayload') == 'bootPayload']
                    if len(matched) != 1: raise ValueError('Expected one native channel trace per startup')
                    sample['channel'] = matched[0]
                    marked = [ch for at, cp, ch in channels if cp == pid and 0 <= timestamp - at < 3
                              and ch.get('method') == 'markBooting']
                    if len(marked) > 1: raise ValueError('Duplicate markBooting trace')
                    if marked: sample['mark_channel'] = marked[0]
                profiles.append(sample)
            item['profiles'] = profiles
            item['breakdown'] = {k: dict(stats([r['buckets_us'][k] for r in profiles]),
                percent_of_total=statistics.mean(r['buckets_us'][k] for r in profiles) / total * 100)
                for k in profiles[0]['buckets_us']}
            if channels:
                item['channel_stages'] = {k: stats([s['channel'][k] for s in profiles])
                    for k in profiles[0]['channel'] if k.endswith('_us')}
                item['native_lock_wait'] = stats([s['raw']['native']['lock_wait'] for s in profiles])
                item['outside_java_channel'] = stats([row['payload_us'] - sample['channel']['total_us']
                    for row, sample in zip(rows, profiles)])
                item['dart_channel_stages'] = {k: stats([s['raw']['dart_channel'][k] for s in profiles])
                    for k in profiles[0]['raw']['dart_channel']}
        report['tiers'][tier] = item
    report['whole_minus_lean_ms'] = {
        k: report['tiers']['whole']['stages'][k]['mean_ms'] - report['tiers']['lean']['stages'][k]['mean_ms']
        for k in STAGES}
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--assert-budget', action='store_true')
    args = parser.parse_args()
    report = analyze(args.run)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    for name, item in report['tiers'].items():
        print(name, json.dumps({k: round(v['mean_ms'], 3) for k, v in item['stages'].items()}))
    failed = [tier for tier, item in report['tiers'].items() if not item['budget_passed']]
    if args.assert_budget and failed:
        raise SystemExit('BOOTSTRAP_OVER_BUDGET: ' + ', '.join(failed))


if __name__ == '__main__':
    main()
