import 'dart:typed_data';

import 'package:bluebird/bluebird.dart';
import 'package:bluebird_platform_interface/bluebird_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_platform.dart';
import 'protos.dart';

void main() {
  late BluetoothDevice device;

  setUp(() {
    FakePlatform.install(FakePlatform());
    device = Bluebird.deviceForAddress('AA:BB:CC:DD:EE:FF');
  });

  BmConnectionStateEvent conn(BmConnectionStateEnum state, {int? code, String? reason}) => BmConnectionStateEvent(
        address: device.remoteId,
        connectionState: state,
        disconnectReasonCode: code,
        disconnectReasonString: reason,
      );

  group('connection state', () {
    test('connected sets isConnected and reports no disconnect reason', () {
      final event = device.handleConnectionStateEvent(conn(BmConnectionStateEnum.connected));
      expect(device.isConnected, isTrue);
      expect(event.connectionState, BluetoothConnectionState.connected);
      expect(event.disconnectReason, isNull);
    });

    test('disconnected clears mtu, records the reason, and reports it', () {
      device.handleConnectionStateEvent(conn(BmConnectionStateEnum.connected));
      device.handleMtuChangedEvent(BmMtuChangedEvent(address: device.remoteId, mtu: 515));
      expect(device.mtuNow, 515);

      final event = device.handleConnectionStateEvent(conn(BmConnectionStateEnum.disconnected, code: 19, reason: 'peer'));
      expect(device.isDisconnected, isTrue);
      expect(device.mtuNow, 23); // reset to default
      expect(event.disconnectReason?.code, 19);
      expect(event.disconnectReason?.description, 'peer');
      expect(device.disconnectReason?.code, 19);
    });
  });

  test('mtu change updates mtuNow', () {
    final event = device.handleMtuChangedEvent(BmMtuChangedEvent(address: device.remoteId, mtu: 247));
    expect(device.mtuNow, 247);
    expect(event.mtu, 247);
  });

  test('services reset clears discovered services', () async {
    final fake = FakePlatform()..services = [bmService('a000', characteristics: [bmChar('b001')])];
    FakePlatform.install(fake);
    device = Bluebird.deviceForAddress('AA:BB:CC:DD:EE:FF');
    device.handleConnectionStateEvent(conn(BmConnectionStateEnum.connected));
    await device.discoverServices(subscribeToServicesChanged: false);
    expect(device.services, isNotEmpty);

    device.handleServicesResetEvent(BmServicesResetEvent(address: device.remoteId));
    expect(device.services, isEmpty);
  });

  group('bond state', () {
    test('carries the reported previous state', () {
      final event = device.handleBondStateEvent(BmBondStateEvent(
        address: device.remoteId,
        bondState: BmBondStateEnum.bonded,
        prevState: BmBondStateEnum.bonding,
      ));
      expect(event.bondState, BluetoothBondState.bonded);
      expect(event.prevState, BluetoothBondState.bonding);
    });

    test('falls back to the last known state when no previous is reported', () {
      device.handleBondStateEvent(BmBondStateEvent(address: device.remoteId, bondState: BmBondStateEnum.bonding));
      final event = device.handleBondStateEvent(BmBondStateEvent(address: device.remoteId, bondState: BmBondStateEnum.bonded));
      expect(event.prevState, BluetoothBondState.bonding);
      expect(device.prevBondState, BluetoothBondState.bonding);
    });
  });

  group('characteristic notification', () {
    Future<void> discover() async {
      final fake = FakePlatform()..services = [bmService('a000', characteristics: [bmChar('b001', properties: props(notify: true))])];
      FakePlatform.install(fake);
      device = Bluebird.deviceForAddress('AA:BB:CC:DD:EE:FF');
      device.handleConnectionStateEvent(conn(BmConnectionStateEnum.connected));
      await device.discoverServices(subscribeToServicesChanged: false);
    }

    test('resolved notification routes to the characteristic and stream', () async {
      await discover();
      final c = device.services.single.characteristics.single;
      final ref = BmCharacteristicRef(service: device.services.single.bm, characteristic: attr('b001'));

      final received = expectLater(c.notifications, emits([1, 2, 3]));
      final event = device.handleCharacteristicNotification(
        BmCharacteristicNotificationEvent(address: device.remoteId, characteristic: ref, value: Uint8List.fromList([1, 2, 3])),
      );
      expect(event, isNotNull);
      expect(event!.value, [1, 2, 3]);
      expect(event.characteristic, c);
      await received;
    });

    test('notification for an unknown characteristic is dropped (null)', () async {
      await discover();
      final ref = BmCharacteristicRef(service: device.services.single.bm, characteristic: attr('bfff'));
      final event = device.handleCharacteristicNotification(
        BmCharacteristicNotificationEvent(address: device.remoteId, characteristic: ref, value: Uint8List.fromList([0])),
      );
      expect(event, isNull);
    });
  });
}
