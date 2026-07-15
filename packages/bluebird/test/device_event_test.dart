import 'package:bluebird/bluebird.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_platform.dart';
import 'protos.dart';

/// Unit tests for [BluetoothDevice.applyEvent]: each app-level event updates
/// the device's own state. The `Bm…Event` → `On…Event` translation is
/// Bluebird's responsibility and is covered in event_routing_test.dart.
void main() {
  late BluetoothDevice device;

  setUp(() {
    FakePlatform.install(FakePlatform());
    device = Bluebird.deviceForAddress('AA:BB:CC:DD:EE:FF');
  });

  OnConnectionStateChangedEvent connEvent(BluetoothConnectionState state, [DisconnectReason? reason]) =>
      OnConnectionStateChangedEvent(device, state, reason);

  group('connection state', () {
    test('connected sets isConnected', () {
      device.applyEvent(connEvent(BluetoothConnectionState.connected));
      expect(device.isConnected, isTrue);
      expect(device.connectionState.value, BluetoothConnectionState.connected);
    });

    test('disconnected clears mtu and records the reason', () {
      device.applyEvent(connEvent(BluetoothConnectionState.connected));
      device.applyEvent(OnMtuChangedEvent(device, 515));
      expect(device.mtu.value, 515);

      device.applyEvent(connEvent(BluetoothConnectionState.disconnected, DisconnectReason(19, 'peer')));
      expect(device.isDisconnected, isTrue);
      expect(device.mtu.value, 23); // reset to default
      expect(device.disconnectReason?.code, 19);
      expect(device.disconnectReason?.description, 'peer');
    });
  });

  test('mtu change updates mtu.value', () {
    device.applyEvent(OnMtuChangedEvent(device, 247));
    expect(device.mtu.value, 247);
  });

  test('services reset invalidates and clears discovered services', () async {
    final fake = FakePlatform()..services = [bmService('a000', characteristics: [bmChar('b001')])];
    FakePlatform.install(fake);
    device = Bluebird.deviceForAddress('AA:BB:CC:DD:EE:FF');
    device.applyEvent(connEvent(BluetoothConnectionState.connected));
    await device.discoverServices(subscribeToServicesChanged: false);
    final char = device.services.single.characteristics.single;

    // a reset invalidates every discovered attribute and clears the tree, so a
    // held reference fails loudly until the caller re-discovers.
    device.applyEvent(OnServicesResetEvent(device));
    expect(device.services, isEmpty);
    expect(char.isValid, isFalse);
    await expectLater(char.read(), throwsA(isA<BluebirdException>()));
  });

  test('re-discovery invalidates every previously discovered attribute', () async {
    final fake = FakePlatform()
      ..services = [
        bmService('a000', characteristics: [bmChar('b001'), bmChar('b002')]),
      ];
    FakePlatform.install(fake);
    device = Bluebird.deviceForAddress('AA:BB:CC:DD:EE:FF');
    device.applyEvent(connEvent(BluetoothConnectionState.connected));
    await device.discoverServices(subscribeToServicesChanged: false);
    final oldService = device.services.single;
    final oldChar = oldService.characteristics.first;

    // re-discovering (even an identical layout) rebuilds the tree from scratch —
    // old objects are invalidated rather than reused, since their identity token
    // cannot be safely re-matched.
    await device.discoverServices(subscribeToServicesChanged: false);

    expect(identical(device.services.single, oldService), isFalse);
    expect(oldService.isValid, isFalse);
    expect(oldChar.isValid, isFalse);
    await expectLater(oldChar.read(), throwsA(isA<BluebirdException>()));

    // the freshly discovered tree is valid and usable
    expect(device.services.single.characteristics.first.isValid, isTrue);
  });

  test('disconnect invalidates attributes and reports deviceDisconnected first', () async {
    final fake = FakePlatform()..services = [bmService('a000', characteristics: [bmChar('b001')])];
    FakePlatform.install(fake);
    device = Bluebird.deviceForAddress('AA:BB:CC:DD:EE:FF');
    device.applyEvent(connEvent(BluetoothConnectionState.connected));
    await device.discoverServices(subscribeToServicesChanged: false);
    final char = device.services.single.characteristics.single;
    expect(char.isValid, isTrue);

    // a disconnect invalidates held attributes; using one blames the disconnect,
    // not a re-discovery
    device.applyEvent(connEvent(BluetoothConnectionState.disconnected));
    expect(device.services, isEmpty);
    expect(char.isValid, isFalse);
    await expectLater(
      char.read(),
      throwsA(isA<BluebirdException>().having((e) => e.code, 'code', BluebirdErrorCode.deviceDisconnected)),
    );

    // reconnecting (without re-discovering) leaves it stale — now the cause is
    // that it must be re-fetched
    device.applyEvent(connEvent(BluetoothConnectionState.connected));
    expect(char.isValid, isFalse);
    await expectLater(
      char.read(),
      throwsA(isA<BluebirdException>().having((e) => e.code, 'code', BluebirdErrorCode.invalidIdentifier)),
    );
  });

  test('bond state event stores the bond state and previous state', () {
    device.applyEvent(OnBondStateChangedEvent(device, BluetoothBondState.bonded, BluetoothBondState.bonding));
    expect(device.currentBondState, BluetoothBondState.bonded);
    expect(device.prevBondState, BluetoothBondState.bonding);
  });
}
