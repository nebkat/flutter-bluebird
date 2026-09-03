import 'dart:async';

import 'package:bluebird/bluebird.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_platform.dart';

/// A platform call that never returns — the state CoreBluetooth leaves a
/// `connect` in when the peripheral is powered off or out of range, and the
/// shape of every "the whole plugin is wedged" report.
///
/// Giving up on such a call has to release the platform queue, or the queue is
/// held for the life of the process and every later call — a scan, a read, the
/// disconnect meant to cancel this very attempt — waits behind it forever.
void main() {
  late FakePlatform fake;
  late BluetoothDevice device;

  /// Whether [future] settles within [within]; false means it is still pending.
  Future<bool> settles(Future<void> future, {Duration within = const Duration(seconds: 1)}) {
    var settled = false;
    unawaited(future.then((_) => settled = true, onError: (_) => settled = true));
    return Future<bool>.delayed(within, () => settled);
  }

  late Completer<void> stuck;

  setUp(() {
    fake = FakePlatform();
    FakePlatform.install(fake);
    device = Bluebird.deviceForAddress('AA:BB:CC:DD:EE:FF');
    stuck = Completer<void>();
    fake.stubs['connect'] = () => stuck.future;
  });

  // let go of the abandoned call, so its timeout timer does not hold the test
  // isolate open until it fires
  tearDown(() {
    if (!stuck.isCompleted) stuck.complete();
  });

  test('connect(timeout:) gives up on a platform connect that never returns', () async {
    expect(await settles(device.connect(timeout: const Duration(milliseconds: 50))), isTrue);
  });

  test('a stuck platform connect does not wedge every later call', () async {
    unawaited(device.connect(timeout: const Duration(milliseconds: 50)).then((_) {}, onError: (_) {}));
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(await settles(Bluebird.isSupported), isTrue);
  });

  test('disconnect(queue: false) cancels an in-flight connect', () async {
    unawaited(device.connect(timeout: const Duration(seconds: 30)).then((_) {}, onError: (_) {}));
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(await settles(device.disconnect(queue: false)), isTrue);
    expect(fake.calls, contains('disconnect'));
  });

  test('a timed-out connect cancels itself on the platform, and can be retried', () async {
    await expectLater(
      device.connect(timeout: const Duration(milliseconds: 50)),
      throwsA(isA<BluebirdException>().having((e) => e.code, 'code', BluebirdErrorCode.timeout)),
    );
    expect(fake.calls, contains('disconnect'));
    expect(device.isConnected, isFalse);

    fake.stubs.remove('connect');
    await device.connect();
    expect(device.isConnected, isTrue);
  });
}
