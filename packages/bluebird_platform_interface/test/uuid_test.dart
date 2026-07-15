import 'package:bluebird_platform_interface/bluebird_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Uuid equality', () {
    test('is by value, not identity', () {
      expect(Uuid('180a'), equals(Uuid('180a')));
      expect(Uuid('0000180a-0000-1000-8000-00805f9b34fb'),
          equals(Uuid('0000180a-0000-1000-8000-00805f9b34fb')));
    });

    test('short and long forms of the same uuid compare equal', () {
      expect(Uuid('180a'), equals(Uuid('0000180a-0000-1000-8000-00805f9b34fb')));
      expect(Uuid('2902'), equals(Uuid('00002902-0000-1000-8000-00805f9b34fb')));
    });

    test('is case-insensitive', () {
      expect(Uuid('6E400001-B5A3-F393-E0A9-E50E24DCCA9E'), equals(Uuid('6e400001-b5a3-f393-e0a9-e50e24dcca9e')));
    });

    test('well-known constants match parsed instances', () {
      expect(Uuids.descriptor.clientCharacteristicConfiguration, equals(Uuid('2902')));
      expect(Uuids.descriptor.characteristicUserDescription, equals(Uuid('2901')));
      expect(Uuids.service.genericAttribute, equals(Uuid('1801')));
      expect(Uuids.characteristic.serviceChanged, equals(Uuid('2a05')));
    });

    test('different uuids compare unequal', () {
      expect(Uuid('180a'), isNot(equals(Uuid('180f'))));
    });

    test('hashCode is consistent with ==', () {
      expect(Uuid('180a').hashCode, equals(Uuid('0000180a-0000-1000-8000-00805f9b34fb').hashCode));
      expect(<Uuid>{Uuid('180a'), Uuid('0000180a-0000-1000-8000-00805f9b34fb')}.length, 1);
    });
  });

  group('Uuid forms', () {
    test('parses 16-, 32-, and 128-bit inputs', () {
      expect(Uuid('180a').bytes.length, 2);
      expect(Uuid('0000180a').bytes.length, 4);
      expect(Uuid('6e400001-b5a3-f393-e0a9-e50e24dcca9e').bytes.length, 16);
    });

    test('string is the shortest form, string128 the expanded form', () {
      expect(Uuid('180a').string, '180a');
      expect(Uuid('180a').string128, '0000180a-0000-1000-8000-00805f9b34fb');
      expect(Uuid('0000180a').string, '0000180a');
      // a 128-bit uuid on the SIG base collapses to its 16-bit short code
      expect(Uuid('0000180a-0000-1000-8000-00805f9b34fb').string, '180a');
      final full = '6e400001-b5a3-f393-e0a9-e50e24dcca9e';
      expect(Uuid(full).string, full);
      expect(Uuid(full).string128, full);
    });

    test('toString equals the shortest form', () {
      expect(Uuid('180a').toString(), '180a');
    });
  });

  group('Uuid validation', () {
    test('rejects wrong lengths', () {
      expect(() => Uuid('18'), throwsFormatException);
      expect(() => Uuid('180a0'), throwsFormatException);
    });

    test('rejects a malformed 128-bit layout', () {
      expect(() => Uuid('6e400001xb5a3-f393-e0a9-e50e24dcca9e'), throwsFormatException);
    });

    test('rejects non-hex characters', () {
      expect(() => Uuid('zzzz'), throwsFormatException);
    });

    test('fromBytes requires 2, 4, or 16 bytes', () {
      expect(() => Uuid.fromBytes([1, 2, 3]), throwsA(isA<AssertionError>()));
      expect(Uuid.fromBytes([1, 2]).bytes.length, 2);
    });
  });

  group('Uuid.name', () {
    test('resolves well-known SIG names, short or long form', () {
      expect(Uuid('2A24').name, 'Model Number String');
      expect(Uuid('0000180a-0000-1000-8000-00805f9b34fb').name, 'Device Information');
      expect(Uuid('2902').name, 'Client Characteristic Configuration');
      expect(Uuids.characteristic.pnpId.name, 'PnP ID');
    });

    test('is null for unknown and non-SIG UUIDs', () {
      expect(Uuid('2AFF').name, isNull); // unassigned in our subset
      expect(Uuid('6e400001-b5a3-f393-e0a9-e50e24dcca9e').name, isNull); // custom 128-bit
    });
  });
}
