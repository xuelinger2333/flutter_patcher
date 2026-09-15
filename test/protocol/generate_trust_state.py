"""Public RFC8032 fixture keys; never use these keys in a deployed host."""
import base64
import json
import hashlib
import struct
from pathlib import Path
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

root = Ed25519PrivateKey.from_private_bytes(bytes.fromhex(
    '9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60'))
b64 = lambda b: base64.b64encode(b).decode()
public = b64(root.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw))
publisher = Ed25519PrivateKey.from_private_bytes(bytes.fromhex(
    '4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb'))
publisher_public = b64(publisher.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw))
scope = dict(application_id='com.example.authfixture', channel='stable', flavor='default',
             version_code='1', abi='arm64-v8a', fingerprint='a'*64, strategy='bytecode')
def sign(fields, domain, key=root):
    payload = json.dumps(fields, sort_keys=True, separators=(',', ':')).encode()
    return json.dumps(dict(payload=b64(payload), signature=b64(key.sign(domain.encode()+payload))), separators=(',', ':'))
def manifest(revision, action='publish', seq='7'):
    fields = dict(scope, schema='1', key_id='release', revision=str(revision), minPluginVersion='0.0.0', action=action)
    fields.update(dict(patch_seq=seq, size='4', sha256='b'*64, url='https://example.com/patch') if action == 'publish' else dict(withdraw_through_seq=seq))
    return sign(fields, 'flutter_patcher.manifest.v1\n')
result = dict(scope=scope, public=public, publish=manifest(1), newer=manifest(2, seq='8'),
              withdraw=manifest(3, 'withdraw'),
              revoke=sign(dict(scope, schema='1', revision='1', keys='-'), 'flutter_patcher.trust.v1\n'),
              restore=sign(dict(scope, schema='1', revision='2', keys='release:'+public), 'flutter_patcher.trust.v1\n'))
result.update(
    publisher_public=publisher_public,
    add_publisher=sign(dict(scope, schema='1', revision='1',
        keys='next:'+publisher_public+',release:'+public), 'flutter_patcher.trust.v1\n'),
    retire_release=sign(dict(scope, schema='1', revision='2',
        keys='next:'+publisher_public), 'flutter_patcher.trust.v1\n'),
    next_publish=sign(dict(scope, schema='1', key_id='next', revision='2',
        minPluginVersion='0.0.0', action='publish', patch_seq='8', size='4',
        sha256='d'*64, url='https://example.com/next'), 'flutter_patcher.manifest.v1\n', publisher))
out = Path(__file__).resolve().parents[2]/'android/src/androidTest/assets/auth-state.json'
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(json.dumps(result, indent=2)+'\n')

# Instrumentation-only host and small signed envelopes for deterministic races.
# The URL handler pauses reads; the real manager still verifies and commits bytes.
scope = dict(scope, application_id='com.flutter_patcher.flutter_patcher.test', version_code='1')
policy = {k: v for k, v in scope.items() if k != 'fingerprint'}
policy.update(schema='1', fptc_key=public, root_key=public, keys='release:'+public)
text = json.dumps(policy, sort_keys=True, separators=(',', ':'))
race = dict(public=public, fingerprint=scope['fingerprint'], policy=dict(policy=text,
    policy_sha256=hashlib.sha256(text.encode()).hexdigest(), fingerprint=scope['fingerprint']))
for seq, revision in [(7, 1), (8, 3), (9, 4), (10, 5), (11, 6)]:
    payload = bytes([seq])*4
    header = b'FPTC'+struct.pack('>H', 1)+bytes.fromhex(scope['fingerprint'])
    header += struct.pack('>IQ', seq, len(payload))+hashlib.sha256(payload).digest()
    envelope = header+root.sign(header+payload)+payload
    race['bytes'+str(seq)] = b64(envelope)
    race['publish'+str(seq)] = sign(dict(scope, schema='1', key_id='release', revision=str(revision),
        minPluginVersion='0.0.0', action='publish', patch_seq=str(seq), size=str(len(envelope)),
        sha256=hashlib.sha256(envelope).hexdigest(), url='https://race.test/'+str(seq)),
        'flutter_patcher.manifest.v1\n')
race['withdraw'] = sign(dict(scope, schema='1', key_id='release', revision='2',
    minPluginVersion='0.0.0', action='withdraw', withdraw_through_seq='7'), 'flutter_patcher.manifest.v1\n')
race['revoke'] = sign(dict(scope, schema='1', revision='1', keys='-'), 'flutter_patcher.trust.v1\n')
out.with_name('auth-races.json').write_text(json.dumps(race, indent=2)+'\n')
