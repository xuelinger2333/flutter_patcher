import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_patcher/src/bootstrap/transport.dart';

void main() {
  test('ordinary calls do not probe FFI and selected channel stays selected',
      () async {
    var probes = 0;
    var available = false;
    final calls = <String>[];
    final transport = BootstrapTransport(
        open: () {
          probes++;
          return available
              ? (method, args) async => calls.add('ffi:$method')
              : null;
        },
        channel: (method, args) async => calls.add('channel:$method'));
    await transport.call('reportBootSuccess', {});
    await transport.call('markBooting', {});
    expect(probes, 0);
    await transport.call('bootPayload', {});
    available = true;
    await transport.call('bootPayload', {});
    await transport.call('markBooting', {});
    expect(probes, 1);
    expect(calls, [
      'channel:reportBootSuccess',
      'channel:markBooting',
      'channel:bootPayload',
      'channel:bootPayload',
      'channel:markBooting'
    ]);
  });

  test('FFI timeout preserves selection and never replays through channel',
      () async {
    var channelCalls = 0;
    final transport = BootstrapTransport(
        open: () => (method, args) async => throw TimeoutException('in flight'),
        channel: (method, args) async {
          channelCalls++;
          return null;
        });
    await expectLater(
        transport.call('bootPayload', {}), throwsA(isA<TimeoutException>()));
    await expectLater(
        transport.call('markBooting', {}), throwsA(isA<TimeoutException>()));
    expect(channelCalls, 0);
  });
  test('unavailable bridge selects channel once for the whole attempt',
      () async {
    var probes = 0;
    final calls = <String>[];
    final transport = BootstrapTransport(open: () {
      probes++;
      return null;
    }, channel: (method, args) async {
      calls.add(method);
      return null;
    });
    await transport.call('bootPayload', {});
    await transport.call('markBooting', {});
    expect(probes, 1);
    expect(calls, ['bootPayload', 'markBooting']);
  });

  test('FFI rejection never replays a consumed request on the channel',
      () async {
    final channel = <String>[];
    final ffi = <String>[];
    final transport = BootstrapTransport(
        open: () => (method, args) async {
              ffi.add(method);
              throw StateError('Rejected after dispatch');
            },
        channel: (method, args) async {
          channel.add(method);
          return null;
        });
    await expectLater(transport.call('bootPayload', {}), throwsStateError);
    await expectLater(transport.call('markBooting', {}), throwsStateError);
    await transport.call('reportDartBootError', {});
    expect(ffi, ['bootPayload', 'markBooting']);
    expect(channel, ['reportDartBootError']);
  });

  test(
      'successful FFI uses the same transport for mark and channels for reports',
      () async {
    final calls = <String>[];
    final transport = BootstrapTransport(
        open: () => (method, args) async {
              calls.add('ffi:$method');
              return true;
            },
        channel: (method, args) async {
          calls.add('channel:$method');
          return null;
        });
    await transport.call('bootPayload', {});
    await transport.call('markBooting', {});
    await transport.call('reportBootSuccess', {});
    expect(calls,
        ['ffi:bootPayload', 'ffi:markBooting', 'channel:reportBootSuccess']);
  });
}
