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
}
