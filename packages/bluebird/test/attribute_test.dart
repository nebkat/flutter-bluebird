import 'package:bluebird/bluebird.dart';
import 'package:bluebird_platform_interface/bluebird_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_platform.dart';
import 'protos.dart';

void main() {
  group('BluetoothAttributeId', () {
    test('equality is value-based on uuid and index, treating null index as 0', () {
      expect(BluetoothAttributeId(Uuid('180d'), 0), BluetoothAttributeId(Uuid('180d')));
      expect(BluetoothAttributeId(Uuid('180d'), 0).hashCode, BluetoothAttributeId(Uuid('180d')).hashCode);
      expect(BluetoothAttributeId(Uuid('180d'), 1), isNot(BluetoothAttributeId(Uuid('180d'), 0)));
      expect(BluetoothAttributeId(Uuid('180d')), isNot(BluetoothAttributeId(Uuid('180f'))));
    });

    test('uuid compares across short/long forms', () {
      final short = BluetoothAttributeId(Uuid('180d'));
      final long = BluetoothAttributeId(Uuid('0000180d-0000-1000-8000-00805f9b34fb'));
      expect(short, long);
    });

    test('round-trips through the wire form', () {
      final id = BluetoothAttributeId(Uuid('180d'), 3);
      final back = BluetoothAttributeId.fromBm(id.bm);
      expect(back, id);
      expect(id.bm.instance, 3);
    });
  });

  group('attribute resolution', () {
    late BluetoothDevice device;

    Future<void> discover(List<BmBluetoothService> services) async {
      final fake = FakePlatform()..services = services;
      FakePlatform.install(fake);
      device = Bluebird.deviceForAddress('AA:BB:CC:DD:EE:FF');
      device.applyEvent(
        OnConnectionStateChangedEvent(device, BluetoothConnectionState.connected, null),
      );
      await device.discoverServices(subscribeToServicesChanged: false);
    }

    test('duplicate-uuid characteristics resolve to distinct instances', () async {
      await discover([
        bmService('a000', characteristics: [
          bmChar('b001', instance: 0),
          bmChar('b001', instance: 1),
        ]),
      ]);

      final service = device.services.single;
      final ref0 = BmCharacteristicRef(service: service.bm, characteristic: attr('b001', 0));
      final ref1 = BmCharacteristicRef(service: service.bm, characteristic: attr('b001', 1));

      expect(device.characteristicForRef(ref0).index, 0);
      expect(device.characteristicForRef(ref1).index, 1);
      expect(device.characteristicForRef(ref0), isNot(device.characteristicForRef(ref1)));
    });

    test('unknown characteristic ref throws characteristicNotFound', () async {
      await discover([bmService('a000', characteristics: [bmChar('b001')])]);
      final ref = BmCharacteristicRef(service: device.services.single.bm, characteristic: attr('bfff'));
      expect(
        () => device.characteristicForRef(ref),
        throwsA(isA<BluebirdException>().having((e) => e.code, 'code', BluebirdErrorCode.characteristicNotFound)),
      );
    });

    test('descriptor resolves within its characteristic', () async {
      await discover([
        bmService('a000', characteristics: [
          bmChar('b001', descriptors: ['2902', '2901']),
        ]),
      ]);
      final chrRef = BmCharacteristicRef(service: device.services.single.bm, characteristic: attr('b001'));
      final descRef = BmDescriptorRef(characteristic: chrRef, id: attr('2901'));
      expect(device.descriptorForRef(descRef).uuid, Uuid('2901'));
    });

    test('included secondary service is linked with a parent back-reference', () async {
      final secondary = bmService('a100', isPrimary: false, characteristics: [bmChar('c001')]);
      final primary = bmService('a000', characteristics: [bmChar('b001')], includedServices: [
        BmServiceRef(service: secondary.id),
      ]);
      await discover([primary, secondary]);

      final primarySvc = device.services.firstWhere((s) => s.uuid == Uuid('a000'));
      expect(primarySvc.includedServices.single.uuid, Uuid('a100'));
      expect(primarySvc.includedServices.single.isSecondary, isTrue);
      // the secondary's ref carries its parent, so a characteristic ref through
      // it round-trips to the same characteristic
      final secSvc = primarySvc.includedServices.single;
      expect(secSvc.bm.parentService?.uuid, Uuid('a000'));
      final ref = BmCharacteristicRef(service: secSvc.bm, characteristic: attr('c001'));
      expect(device.characteristicForRef(ref).uuid, Uuid('c001'));
    });
  });
}
