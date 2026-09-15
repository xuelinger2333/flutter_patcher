"""Regenerate public test vectors: Python + cryptography, never production keys."""
import base64
import hashlib
import json
from pathlib import Path
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

# RFC 8032 public test seed, deliberately not a production secret.
key = Ed25519PrivateKey.from_private_bytes(bytes.fromhex(
    '9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60'))
public = key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw).hex()
base = dict(schema='1', key_id='release', application_id='com.example.app',
            channel='stable', flavor='default', version_code='1', abi='arm64-v8a',
            fingerprint='ab' * 32, strategy='bytecode', revision='1',
            minPluginVersion='2.0.0', action='publish', patch_seq='1',
            sha256='cd' * 32, size='147', url='https://updates.example/app.fptc')
scope = {k: base[k] for k in ['application_id', 'channel', 'flavor',
         'version_code', 'abi', 'fingerprint', 'strategy']}
dump = lambda obj: json.dumps(obj, sort_keys=True, separators=(',', ':'))
digest = lambda obj: hashlib.sha256(dump(obj).encode()).hexdigest()
state = dict(revision=1, manifestHash=digest(base), highSeq=1,
             patchHash=base['sha256'], withdrawnThrough=0)
vectors = []


def add(name, fields=None, *, parse=True, verify=True, raw=None, previous=None,
        target=None, version='2.0.0', tamper=False, wire_edit=None, action=None):
    fields = base if fields is None else fields
    payload = (dump(fields) if raw is None else raw).encode()
    message = b'flutter_patcher.manifest.v1\n' + payload
    signature = key.sign(message)
    if tamper:
        signature = bytes([signature[0] ^ 1]) + signature[1:]
    wire = dump(dict(payload=base64.b64encode(payload).decode(),
                     signature=base64.b64encode(signature).decode()))
    if wire_edit:
        wire = wire_edit(wire)
    vectors.append(dict(name=name, public_key=public, payload=base64.b64encode(payload).decode(),
        signing_hex=message.hex(), signature=signature.hex(), wire=wire,
        parse_valid=parse, verify_valid=verify, envelope_valid=wire_edit is None,
        scope=scope if target is None else target, plugin_version=version,
        state=previous or {}, action=action or fields.get('action')))


add('publish')
add('same-revision-idempotent', previous=state)
add('same-seq-new-url', dict(base, revision='2', url='https://cdn.example/app.fptc'), previous=state)
add('new-seq', dict(base, revision='2', patch_seq='2'), previous=state)
add('unknown-key', dict(base, key_id='unknown'), verify=False)
add('bad-signature', tamper=True, verify=False)
add('wrong-scope', target=dict(scope, channel='beta'), verify=False)
add('old-plugin', version='1.99.99', verify=False)
add('newer-plugin', version='3.0.0')
add('numeric-version-order', dict(base, minPluginVersion='2.9.0'), version='2.10.0')
add('https-query', dict(base, url='https://cdn.example:443/a?key=a%2Fb&x=1'))
add('stale-revision', previous=dict(state, revision=2), verify=False)
add('revision-conflict', dict(base, size='148'), previous=state, verify=False)
add('sequence-conflict', dict(base, revision='2', sha256='ef'*32), previous=state, verify=False)
withdraw = {k: v for k, v in base.items() if k not in ['patch_seq', 'sha256', 'size', 'url']}
withdraw.update(action='withdraw', revision='2', withdraw_through_seq='1')
add('withdraw', withdraw, previous=state)
withdrawn = dict(state, revision=2, manifestHash=digest(withdraw), withdrawnThrough=1)
add('withdraw-idempotent', withdraw, previous=withdrawn)
add('republish-withdrawn', dict(base, revision='3'), previous=withdrawn, verify=False)
add('republish-new-seq', dict(base, revision='3', patch_seq='2'), previous=withdrawn)
add('old-publish-after-withdraw', previous=withdrawn, verify=False)
add('lower-withdraw-floor', dict(withdraw, revision='3'),
    previous=dict(withdrawn, highSeq=5, withdrawnThrough=5))
add('legacy-so-new-protocol', dict(base, strategy='so', fingerprint='-'),
    target=dict(scope, strategy='so', fingerprint='-'))
for field, value in [('schema', '2'), ('revision', '01'), ('revision', '9007199254740992'),
    ('patch_seq', '0'), ('patch_seq', '4294967296'), ('size', '335544321'),
    ('minPluginVersion', '2.0.0-dev.1'), ('abi', 'x86_64'), ('strategy', 'unknown'),
    ('fingerprint', '-'), ('url', 'http://example.com/a'), ('url', 'https://a:b@example.com/a'),
    ('url', 'https://example.com/a#fragment'), ('channel', '中文'), ('unknown', 'field')]:
    add(f'invalid-{field}-{value}', dict(base, **{field: value}), parse=False, verify=False)
for url in ['https://example.com/a%xx', 'https://example.com:99999/a',
            'https://example.com/a|b', 'https://example.com/a%2f', 'https://EXAMPLE.com/a']:
    add('invalid-url-'+url, dict(base, url=url), parse=False, verify=False)
add('missing-field', {k: v for k, v in base.items() if k != 'key_id'}, parse=False, verify=False)
add('duplicate-key', raw=dump(base)[:-1]+',"schema":"1"}', parse=False, verify=False)
add('whitespace', raw=' '+dump(base), parse=False, verify=False)
add('integer-instead-of-string', dict(base, revision=1), parse=False, verify=False)
add('escaped-value', raw=dump(base).replace('stable', r'\u0073table'), parse=False, verify=False)
add('envelope-duplicate', wire_edit=lambda w: w[:-1]+',"signature":"AA=="}', verify=False)
add('envelope-whitespace', wire_edit=lambda w: ' '+w, verify=False)
add('envelope-unknown', wire_edit=lambda w: w[:-1]+',"verified":true}', verify=False)
Path(__file__).with_name('manifest-v1.json').write_text(
    json.dumps(vectors, indent=2, ensure_ascii=True)+'\n', encoding='utf-8')
