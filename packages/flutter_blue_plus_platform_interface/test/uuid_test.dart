import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart';
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
      expect(Uuids.cccdDescriptor, equals(Uuid('2902')));
      expect(Uuids.gattService, equals(Uuid('1801')));
      expect(Uuids.servicesChangedCharacteristic, equals(Uuid('2a05')));
    });

    test('different uuids compare unequal', () {
      expect(Uuid('180a'), isNot(equals(Uuid('180f'))));
    });

    test('hashCode is consistent with ==', () {
      expect(Uuid('180a').hashCode, equals(Uuid('0000180a-0000-1000-8000-00805f9b34fb').hashCode));
      expect(<Uuid>{Uuid('180a'), Uuid('0000180a-0000-1000-8000-00805f9b34fb')}.length, 1);
    });
  });
}
