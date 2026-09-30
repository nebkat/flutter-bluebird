import 'dart:async';

import 'package:bluebird/bluebird.dart';
import 'package:bluebird_platform_interface/bluebird_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_platform.dart';

/// The platforms order a device's operations; Dart only orders connects.
void main() {
  late FakePlatform fake;
  late BluetoothDevice device;

  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

  int callsTo(String method) => fake.calls.where((c) => c == method).length;

  setUp(() async {
    fake = FakePlatform();
    FakePlatform.install(fake);
    device = Bluebird.deviceForAddress('AA:BB:CC:DD:EE:FF');
    await device.connect();
    fake.calls.clear();
  });

  test("a device's operations reach the platform without waiting on one another", () async {
    final rssi = Completer<int>();
    fake.stubs['readRssi'] = () => rssi.future;

    final reads = [device.readRssi(), device.readRssi()];
    await settle();
    expect(callsTo('readRssi'), 2);

    rssi.complete(-50);
    expect(await Future.wait(reads), [-50, -50]);
  });

  test('connects are made one at a time, across devices', () async {
    final stuck = Completer<void>();
    fake.stubs['connect'] = () => stuck.future;

    final connects = [
      Bluebird.deviceForAddress('11:22:33:44:55:66').connect(),
      Bluebird.deviceForAddress('22:33:44:55:66:77').connect(),
    ];
    await settle();
    expect(callsTo('connect'), 1);

    stuck.complete();
    await Future.wait(connects);
    expect(callsTo('connect'), 2);
  });

  test("a queued disconnect waits out the device's operations in flight", () async {
    final rssi = Completer<int>();
    fake.stubs['readRssi'] = () => rssi.future;

    final read = device.readRssi();
    final disconnect = device.disconnect();
    await settle();
    expect(fake.calls, isNot(contains('disconnect')));

    rssi.complete(-50);
    await read;
    await disconnect;
    expect(fake.calls, contains('disconnect'));
  });

  test("a queued disconnect is not held up by another device's operations", () async {
    final other = Bluebird.deviceForAddress('11:22:33:44:55:66');
    await other.connect();
    final rssi = Completer<int>();
    fake.stubs['readRssi'] = () => rssi.future;

    final read = other.readRssi();
    await device.disconnect();
    expect(fake.calls, contains('disconnect'));

    rssi.complete(-50);
    await read;
  });

  test("an unqueued disconnect does not wait for the device's operations", () async {
    final rssi = Completer<int>();
    fake.stubs['readRssi'] = () => rssi.future;

    final read = device.readRssi();
    await device.disconnect(queue: false);
    expect(fake.calls, contains('disconnect'));

    rssi.complete(-50);
    await read;
  });

  test("an abandoned operation does not hold up the device's next one", () async {
    final stuck = Completer<int>();
    fake.stubs['readRssi'] = () => stuck.future;

    await expectLater(
      device.readRssi(timeout: const Duration(milliseconds: 20)),
      throwsA(isA<BluebirdException>().having((e) => e.code, 'code', BluebirdErrorCode.timeout)),
    );

    fake.stubs.remove('readRssi');
    expect(await device.readRssi(), -42);
    stuck.complete(0);
  });

  test('an unsupported platform fails a scan rather than throwing at the listener', () async {
    BluebirdPlatform.instance = _UnsupportedPlatform();
    Bluebird.resetForTest();

    final errors = <Object>[];
    final done = Completer<void>();
    Bluebird.performScan().listen(null, onError: errors.add, onDone: done.complete);
    await done.future;

    expect(errors.single, isUnsupportedError);
  });
}

/// Stands in for a platform with no bluebird implementation, which fails on first use.
final class _UnsupportedPlatform extends BluebirdPlatform {
  @override
  Stream<BmEvent> get events => throw UnsupportedError('bluebird is unsupported on this platform');
}
