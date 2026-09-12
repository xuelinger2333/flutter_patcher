"""Verify frozen records; optionally verify the separate artifact archive."""
import argparse
import hashlib
import json
from pathlib import Path
import tarfile


def digest(stream):
    h = hashlib.sha256()
    for chunk in iter(lambda: stream.read(1024 * 1024), b''):
        h.update(chunk)
    return h.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent
    manifest = json.loads((root / 'manifest.json').read_text(encoding='utf-8'))
    for name, row in manifest['records'].items():
        path = root / name
        assert path.stat().st_size == row['bytes'], name
        with path.open('rb') as stream:
            assert digest(stream) == row['sha256'], name
    print(f"Records verified: {len(manifest['records'])}")
    if args.archive:
        with args.archive.open('rb') as stream:
            assert digest(stream) == manifest['artifact_archive']['sha256'], 'Archive digest'
        expected = manifest['artifacts']
        seen = set()
        with tarfile.open(args.archive, 'r:*') as archive:
            for member in archive:
                assert member.isfile() and member.name in expected and member.name not in seen, member.name
                row = expected[member.name]
                assert member.size == row['bytes'], member.name
                with archive.extractfile(member) as stream:
                    assert digest(stream) == row['sha256'], member.name
                seen.add(member.name)
        assert seen == set(expected), 'Archive entries missing'
        print(f'Artifacts verified: {len(seen)}')


if __name__ == '__main__':
    main()
