import 'dart:typed_data';

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
          bmChar('b001', properties: props(read: true, write: true, notify: true), descriptors: ['2901']),
        ]),
      ];
    FakePlatform.install(fake);
    device = Bluebird.deviceForAddress('AA:BB:CC:DD:EE:FF');
    await device.connect();
    await device.discoverServices(subscribeToServicesChanged: false);
  });

  BluetoothCharacteristic chr() => device.services.single.characteristics.single;
  BluetoothDescriptor dsc() => chr().descriptors.single;

  // bytes <-> int (first byte)
  int decode(List<int> bytes) => bytes.isEmpty ? 0 : bytes.first;
  List<int> encode(int n) => [n];

  test('read decodes the platform bytes to T', () async {
    // fake.readCharacteristic returns [0xab]
    final mapped = chr().map(decode, encode: encode);
    expect(await mapped.read(), 0xab);
  });

  test('write encodes T and forwards to the platform', () async {
    final mapped = chr().map(decode, encode: encode);
    await mapped.write(5);
    expect(fake.lastWriteValue, [5]);
  });

  test('write on a decode-only mapping throws StateError', () async {
    final readOnly = chr().map(decode); // no encode
    expect(() => readOnly.write(5), throwsStateError);
  });

  test('notifications are decoded to T', () async {
    final mapped = chr().map(decode, encode: encode);
    final received = <int>[];
    final sub = mapped.notifications.listen(received.add);
    await pumpEventQueue(); // let notify-enable settle before the event fires

    fake.emit(BmCharacteristicNotificationEvent(
      address: device.remoteId,
      characteristic: chr().bm,
      value: Uint8List.fromList([42]),
    ));
    await pumpEventQueue();

    expect(received, [42]);
    await sub.cancel();
  });

  test('chained map composes decode (and encode)', () async {
    final asText = chr().map(decode, encode: encode).map((n) => 'v$n', encode: int.parse);
    expect(await asText.read(), 'v171'); // 0xab
    await asText.write('7');
    expect(fake.lastWriteValue, [7]);
  });

  test('metadata and streams delegate to the wrapped characteristic', () {
    final raw = chr();
    final mapped = raw.map(decode, encode: encode);
    expect(mapped.raw, same(raw));
    expect(mapped.uuid, raw.uuid);
    expect(mapped.index, raw.index);
    expect(mapped.id, raw.id);
    expect(mapped.device, same(raw.device));
    expect(mapped.service, same(raw.service));
    expect(mapped.properties, raw.properties);
    expect(mapped.descriptors, raw.descriptors);
    expect(mapped.cccd, raw.cccd);
    expect(mapped.canRead, raw.canRead);
    expect(mapped.canWrite, raw.canWrite);
    expect(mapped.canNotify, raw.canNotify);
    expect(mapped.isValid, raw.isValid);
    expect(mapped.toString(), contains('MappedBluetoothCharacteristic'));

    // the stream getters just wrap the raw streams; building them covers the getters
    expect(mapped.notifications, isA<Stream<int>>());
    expect(mapped.notificationsPassive, isA<Stream<int>>());
    expect(mapped.values, isA<Stream<int>>());
    expect(mapped.valuesPassive, isA<Stream<int>>());
  });

  test('subscribe forwards to the wrapped characteristic', () async {
    final mapped = chr().map(decode);
    final sub = await mapped.subscribe();
    expect(sub.isActive, isTrue);
    await sub.unsubscribe();
  });

  group('descriptor', () {
    test('read decodes and write encodes', () async {
      final mapped = dsc().map(decode, encode: encode); // fake.readDescriptor returns [0xcd]
      expect(await mapped.read(), 0xcd);
      await mapped.write(9);
      expect(fake.lastWriteValue, [9]);
    });

    test('write on a decode-only mapping throws StateError', () {
      final readOnly = dsc().map(decode);
      expect(() => readOnly.write(9), throwsStateError);
    });

    test('metadata delegates to the wrapped descriptor', () {
      final raw = dsc();
      final mapped = raw.map(decode);
      expect(mapped.raw, same(raw));
      expect(mapped.uuid, raw.uuid);
      expect(mapped.index, raw.index);
      expect(mapped.id, raw.id);
      expect(mapped.device, same(raw.device));
      expect(mapped.characteristic, same(raw.characteristic));
      expect(mapped.isValid, raw.isValid);
      expect(mapped.toString(), contains('MappedBluetoothDescriptor'));
    });

    test('chained map composes decode and encode', () async {
      final asText = dsc().map(decode, encode: encode).map((n) => 'v$n', encode: int.parse);
      expect(await asText.read(), 'v205'); // 0xcd
      await asText.write('3');
      expect(fake.lastWriteValue, [3]);
    });
  });
}
