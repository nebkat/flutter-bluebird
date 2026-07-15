import 'dart:typed_data';

import 'package:bluebird/bluebird.dart';
import 'package:flutter_test/flutter_test.dart';

import 'protos.dart';

void main() {
  group('AdvertisementData', () {
    test('maps manufacturer and service data, keying service data by Uuid', () {
      final adv = ScanResult.fromProto(
        bmAdv(
          'AA',
          advName: 'dev',
          rssi: -60,
          manufacturerData: {
            0x02e5: Uint8List.fromList([1, 2]),
          },
          serviceData: {
            '180f': Uint8List.fromList([9]),
          },
          serviceUuids: ['180f', '180d'],
        ),
      ).advertisementData;

      expect(adv.advName, 'dev');
      expect(adv.manufacturerData[0x02e5], [1, 2]);
      expect(adv.serviceData[Uuid('180f')], [9]);
      expect(adv.serviceUuids, [Uuid('180f'), Uuid('180d')]);
    });
  });

  group('Phy.mask', () {
    test('uses android PHY_LE_*_MASK bit flags', () {
      expect(Phy.le1m.mask, 1);
      expect(Phy.le2m.mask, 2);
      expect(Phy.leCoded.mask, 4); // regression: was the PHY value 3
    });

    test('maskFrom bitwise-ORs the set', () {
      expect(Phy.maskFrom({}), 0);
      expect(Phy.maskFrom({Phy.le2m}), 2);
      expect(Phy.maskFrom({Phy.le2m, Phy.leCoded}), 6);
      expect(Phy.maskFrom(Phy.values.toSet()), 7);
    });
  });

  group('StreamControllerReEmit', () {
    test('re-emits the latest value to new listeners', () async {
      final c = StreamControllerReEmit<int>(initialValue: 0);
      c.add(1);
      c.add(2);
      expect(c.value, 2);
      expect(await c.stream.first, 2); // late listener still sees the latest
      c.add(3);
      expect(await c.stream.first, 3);
    });
  });

  group('ScanResult', () {
    ScanResult result(String addr, {String? advName, String? platformName, int rssi = -60}) =>
        ScanResult.fromProto(bmAdv(addr, advName: advName, platformName: platformName, rssi: rssi));

    test('equality and hashCode are by address', () {
      final a = result('AA');
      final b = result('AA', rssi: -40);
      final c = result('BB');
      expect(a, equals(b)); // same address, different rssi
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(equals(c)));
      expect(a.device.remoteId, 'AA');
    });

    test('mergedWith carries forward fields the newer packet omits', () {
      final first = result('AA', advName: 'dev', platformName: 'DevName', rssi: -70);
      final second = result('AA', rssi: -50); // scan response: no name
      final merged = first.mergedWith(second);
      expect(merged.rssi, -50); // newer wins
      expect(merged.platformName, 'DevName'); // carried from first
      expect(merged.advertisementData.advName, 'dev'); // carried from first
      expect(first.toString(), contains('ScanResult{'));
      expect(first.advertisementData.toString(), contains('AdvertisementData{'));
    });
  });

  group('BluebirdException', () {
    test('toString includes function, code, description, and optional details', () {
      final e = BluebirdException('readCharacteristic', BluebirdErrorCode.timeout, 'timed out');
      expect(e.toString(), contains('readCharacteristic'));
      expect(e.toString(), contains('timed out'));
      expect(e.toString(), isNot(contains('details')));

      final withDetails = BluebirdException('f', BluebirdErrorCode.cbError, 'x', 'CBATTError 3');
      expect(withDetails.toString(), contains('details: CBATTError 3'));
    });
  });

  group('BluetoothDevice', () {
    test('equality, hashCode, and toString are by remoteId', () {
      final a = Bluebird.deviceForAddress('AA:BB');
      final b = Bluebird.deviceForAddress('AA:BB');
      expect(a, same(b)); // deviceForAddress caches per address
      expect(a.hashCode, 'AA:BB'.hashCode);
      expect(a.toString(), contains('BluetoothDevice{'));
      expect(a.toString(), contains('AA:BB'));
    });
  });

  group('DisconnectReason', () {
    test('toString includes the code and description', () {
      final r = DisconnectReason(19, 'remote user terminated connection');
      expect(r.toString(), contains('19'));
      expect(r.toString(), contains('remote user terminated connection'));
    });
  });
}
