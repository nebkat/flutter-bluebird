import 'dart:async';

import 'package:bluebird/bluebird.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_platform.dart';

/// A platform `connect` that never returns must not hold the platform queue.
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

  // stop the abandoned timeout timer from holding the isolate open
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

  test('disconnect(queue: false) cancels a connect that has not reached the platform', () async {
    // another device's connect holds the connect queue, so this one waits behind it
    final other = Bluebird.deviceForAddress('11:22:33:44:55:66');
    unawaited(other.connect(timeout: const Duration(seconds: 30)).then((_) {}, onError: (_) {}));
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final connect = expectLater(
      device.connect(),
      throwsA(isA<BluebirdException>().having((e) => e.code, 'code', BluebirdErrorCode.userCanceled)),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final disconnect = device.disconnect(queue: false);
    stuck.complete();
    await disconnect;
    await connect;

    expect(fake.calls.where((c) => c == 'connect'), hasLength(1), reason: "only the other device's connect");
    expect(fake.calls, isNot(contains('disconnect')));
    expect(device.isConnected, isFalse);
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
