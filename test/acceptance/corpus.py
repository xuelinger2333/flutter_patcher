"""Generate signed WP-9 cases from real patches. OpenSSL is the signing oracle.

No SDK compilation here. --modules contains CI-built malformed-entry bytecode.
All output is immutable; a new directory is required on every run.
"""
import argparse
import base64
import hashlib
import io
import json
from pathlib import Path
import struct
import subprocess
import zipfile


def digest(data):
    return hashlib.sha256(data).hexdigest()


def stored(files, compression=zipfile.ZIP_STORED):
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, 'w', compression=compression) as archive:
        for name, value in files:
            info = zipfile.ZipInfo(name, (2020, 1, 1, 0, 0, 0))
            info.external_attr = 0o100644 << 16
            info.compress_type = compression
            archive.writestr(info, value)
    return buffer.getvalue()


def generate(lean, whole, modules, seed, out):
    base = lean.read_bytes()
    fp = base[6:38].hex()
    seq = struct.unpack_from('>I', base, 38)[0]
    with zipfile.ZipFile(io.BytesIO(base[146:])) as archive:
        original = {name: archive.read(name) for name in archive.namelist()}
    metadata = json.loads((modules / 'modules.json').read_text())
    tier = json.loads(original['patch_manifest.json'])['tier']
    if (metadata.get('fingerprint'), metadata.get('seq'), metadata.get('tier')) != (fp, seq, tier):
        raise ValueError('Compiled failure modules must match the control fingerprint, sequence and tier')
    if set(metadata['files']) != {'entry-short', 'entry-not-function', 'main-throws', 'main-hangs'}:
        raise ValueError('All four compiled failure modules are required')
    for name, record in metadata['files'].items():
        if name not in ['entry-short', 'entry-not-function', 'main-throws', 'main-hangs']:
            raise ValueError('Unknown failure module')
        data = (modules / f'{name}.bc').read_bytes()
        if len(data) != record['bytes'] or digest(data) != record['sha256']:
            raise ValueError('Compiled failure module changed: ' + name)
    if seq <= 1: raise ValueError('Acceptance control sequence must exceed 1')
    out.mkdir(parents=True, exist_ok=False)
    if len(seed) != 32:
        raise ValueError('Only a dedicated 32-byte test seed is accepted')
    key = out / 'TEST_ONLY_key.der'
    key.write_bytes(bytes.fromhex('302e020100300506032b657004220420') + seed)
    public = subprocess.check_output(['openssl', 'pkey', '-inform', 'DER', '-in', str(key),
                                     '-pubout', '-outform', 'DER'])
    (out / 'TEST_ONLY_public.base64').write_text(base64.b64encode(public[-32:]).decode())
    rows = []

    def envelope(payload, sequence=seq):
        header = b'FPTC' + struct.pack('>H', 1) + bytes.fromhex(fp)
        header += struct.pack('>IQ', sequence, len(payload)) + hashlib.sha256(payload).digest()
        message = out / 'signing-message.bin'
        message.write_bytes(header + payload)
        signature = subprocess.check_output(['openssl', 'pkeyutl', '-sign', '-rawin',
            '-inkey', str(key), '-keyform', 'DER', '-in', str(message)])
        if len(signature) != 64:
            raise ValueError('Invalid Ed25519 signature length')
        return header + signature + payload

    def emit(name, data, layer, reason='', **extra):
        (out / f'{name}.fptc').write_bytes(data)
        rows.append(dict(id=name, file=f'{name}.fptc', layer=layer, reason=reason,
                         bytes=len(data), sha256=digest(data), **extra))

    # These are real control modules. Re-sign using the dedicated acceptance key.
    emit('valid-lean', envelope(base[146:]), 'accept',
         tier=json.loads(original['patch_manifest.json'])['tier'], revision='lean')
    whole_bytes = whole.read_bytes()
    if whole_bytes[6:38].hex() != fp:
        raise ValueError('Controls must target the same baseline')
    emit('valid-whole', envelope(whole_bytes[146:], struct.unpack_from('>I', whole_bytes, 38)[0]),
         'accept', tier='whole', revision='whole')
    good = envelope(base[146:])
    for name, data, reason in [
        ('empty', b'', 'Envelope size'), ('random', b'bad patch' * 30, 'Envelope length'),
        ('truncated-header', good[:81], 'Envelope size'),
        ('truncated-payload', good[:-1], 'Envelope length')]:
        emit(name, data, 'envelope', reason)
    for name, offset, reason in [('magic-bit', 0, 'Envelope magic'),
                                ('fingerprint-bit', 6, 'Envelope fingerprint'),
                                ('signature-bit', 82, 'Envelope signature'),
                                ('payload-bit', 146, 'Envelope hash')]:
        changed = bytearray(good)
        changed[offset] ^= 1
        emit(name, bytes(changed), 'envelope', reason)
    for version in [0, 255]:
        changed = bytearray(good)
        struct.pack_into('>H', changed, 4, version)
        emit(f'version-{version}', bytes(changed), 'envelope', 'Envelope version')
    for delta in [-1, 1]:
        changed = bytearray(good)
        struct.pack_into('>Q', changed, 42, len(good) - 146 + delta)
        emit(f'length-{delta:+d}', bytes(changed), 'envelope', 'Envelope length')
    emit('seq-replay', good, 'state', 'sequence', prerequisite='accept-then-rollback')
    lower = dict(original)
    lower_manifest = json.loads(lower['patch_manifest.json'])
    lower_manifest['patch_seq'] = seq - 1
    lower['patch_manifest.json'] = json.dumps(lower_manifest).encode()
    emit('seq-decrease', envelope(stored(list(lower.items())), seq - 1),
         'state', 'sequence', prerequisite='accept-then-rollback')
    emit('zip-deflate', envelope(stored(list(original.items()), zipfile.ZIP_DEFLATED)),
         'archive', 'ZIP unsupported entry')
    for name, path, reason in [('zip-traversal', '../x', 'ZIP path'),
                               ('zip-unlisted', 'x', 'Unlisted ZIP entries'),
                               ('zip-duplicate', 'module.bc', 'ZIP duplicate/directory')]:
        emit(name, envelope(stored([*original.items(), (path, b'x')])), 'archive', reason)
    zip_bytes = stored(list(original.items()))
    central = struct.unpack_from('<I', zip_bytes, len(zip_bytes) - 6)[0]
    for name, reason in [('zip-encrypted', 'ZIP unsupported entry'),
                         ('zip-oversize-entry', 'ZIP unsupported entry'),
                         ('zip-symlink', 'ZIP non-regular entry'),
                         ('zip-count-limit', 'ZIP directory'),
                         ('zip-crc', 'ZIP CRC')]:
        changed = bytearray(zip_bytes)
        if name == 'zip-encrypted':
            struct.pack_into('<H', changed, 6, 1)
            struct.pack_into('<H', changed, central + 8, 1)
        elif name == 'zip-oversize-entry':
            for offset in [18, 22, central + 20, central + 24]:
                struct.pack_into('<I', changed, offset, 64 * 1024 * 1024 + 1)
        elif name == 'zip-symlink':
            struct.pack_into('<I', changed, central + 38, 0o120777 << 16)
        elif name == 'zip-count-limit':
            struct.pack_into('<HH', changed, len(changed) - 14, 4097, 4097)
        else:
            changed[14] ^= 1
            changed[central + 16] ^= 1
        emit(name, envelope(bytes(changed)), 'archive', reason)
    for name in ['module-truncated', 'asset-hash', 'entry-short', 'entry-not-function', 'main-throws', 'main-hangs']:
        files = dict(original)
        manifest = json.loads(files['patch_manifest.json'])
        if name == 'asset-hash':
            files['assets/fixture.txt'] = b'fixture'
            manifest['assets'].append({'key': 'fixture.txt', 'path': 'assets/fixture.txt',
                                       'length': 3, 'sha256': '0' * 64})
            layer, reason = 'archive', 'Entry digest'
        else:
            module = b'DBC' if name == 'module-truncated' else (modules / f'{name}.bc').read_bytes()
            files['module.bc'] = module
            manifest['module'].update(length=len(module), sha256=digest(module))
            # Malformed entry modules intentionally have no resource installer.
            if name != 'module-truncated':
                files = {k: v for k, v in files.items() if k in ['module.bc', 'patch_manifest.json']}
                manifest.update(assets=[], fonts=[])
            layer, reason = ('archive', 'Bytecode magic') if name == 'module-truncated' else (
                'boot', {'entry-short': 'PatchEntry length', 'entry-not-function': 'PatchEntry contract',
                         'main-throws': 'intentional boot failure',
                         'main-hangs': 'Previous process crashed'}[name])
        files['patch_manifest.json'] = json.dumps(manifest, separators=(',', ':')).encode()
        emit(name, envelope(stored(list(files.items()))), layer, reason)
    report = dict(schema=1, fingerprint=fp, seq=seq, public_key=base64.b64encode(public[-32:]).decode(),
                  cases=rows, device_verified=False)
    (out / 'corpus.json').write_text(json.dumps(report, indent=2) + '\n')
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    for name in ['lean', 'whole', 'modules', 'seed', 'out']:
        parser.add_argument('--' + name, type=Path, required=True)
    args = parser.parse_args()
    generate(args.lean, args.whole, args.modules,
             base64.b64decode(args.seed.read_text().strip(), validate=True), args.out)
