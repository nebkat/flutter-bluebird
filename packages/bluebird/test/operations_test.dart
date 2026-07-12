import 'package:bluebird/bluebird.dart';
import 'package:bluebird_platform_interface/bluebird_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_platform.dart';
import 'protos.dart';

void main() {
  late FakePlatform fake;
  late BluetoothDevice device;

  setUp(() async {
    fake = FakePlatform()
      ..services = [
        bmService('a000', characteristics: [
          bmChar('b001', properties: props(read: true, write: true, writeWithoutResponse: true, notify: true), descriptors: ['2901']),
        ]),
      ];
    FakePlatform.install(fake);
    device = Bluebird.deviceForAddress('AA:BB:CC:DD:EE:FF');
  });

  BluetoothCharacteristic chr() => device.services.single.characteristics.single;

  Future<void> connectAndDiscover() async {
    await device.connect();
    await device.discoverServices(subscribeToServicesChanged: false);
  }

  test('connect marks the device connected and delegates to the platform', () async {
    expect(device.isConnected, isFalse);
    await device.connect();
    expect(fake.calls, contains('connect'));
    expect(device.isConnected, isTrue);
  });

  test('disconnect delegates to the platform', () async {
    await device.connect();
    await device.disconnect();
    expect(fake.calls, contains('disconnect'));
  });

  test('operations on a disconnected device throw deviceDisconnected', () async {
    expect(
      () => device.discoverServices(),
      throwsA(isA<BluebirdException>().having((e) => e.code, 'code', BluebirdErrorCode.deviceDisconnected)),
    );
  });

  test('characteristic read returns the value and emits a received event', () async {
    await connectAndDiscover();
    final events = expectLater(
      Bluebird.events.onCharacteristicReceived,
      emits(isA<OnCharacteristicReceivedEvent>().having((e) => e.value, 'value', [0xab])),
    );
    final value = await chr().read();
    expect(value, [0xab]);
    expect(fake.lastCharRef?.characteristic.uuid, Uuid('b001'));
    await events;
  });

  test('write passes the correct write type', () async {
    await connectAndDiscover();

    await chr().write([1, 2, 3]);
    expect(fake.lastWriteType, BmWriteType.withResponse);
    expect(fake.lastWriteValue, [1, 2, 3]);

    await chr().write([4], withoutResponse: true);
    expect(fake.lastWriteType, BmWriteType.withoutResponse);
  });

  test('setNotifyValue delegates to the platform', () async {
    await connectAndDiscover();
    await chr().setNotifyValue(true);
    expect(fake.calls, contains('setNotifyValue'));
  });

  test('descriptor read/write delegate to the platform', () async {
    await connectAndDiscover();
    final d = chr().descriptors.single;
    expect(await d.read(), [0xcd]);
    await d.write([7]);
    expect(fake.lastWriteValue, [7]);
    expect(fake.calls, containsAll(['readDescriptor', 'writeDescriptor']));
  });

  test('readRssi returns the platform value', () async {
    await connectAndDiscover();
    expect(await device.readRssi(), -42);
  });

  test('android-only operations throw on other platforms', () async {
    await device.connect();
    // host is not Android, so these are gated
    expect(() => device.requestMtu(512), throwsA(isA<BluebirdException>()));
    expect(() => device.createBond(), throwsA(isA<BluebirdException>()));
  });
}
