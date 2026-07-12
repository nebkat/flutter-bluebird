import 'package:bluebird/bluebird.dart';
import 'package:bluebird_platform_interface/bluebird_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_platform.dart';

/// Verifies that Bluebird routes each platform [BmEvent] to the matching
/// public event stream / device state (the `_onPlatformEvent` dispatch).
void main() {
  late FakePlatform fake;

  setUp(() async {
    fake = FakePlatform();
    FakePlatform.install(fake);
    // any invoke() triggers Bluebird to subscribe to the platform event stream
    await Bluebird.isSupported;
  });

  Future<void> pump() => pumpEventQueue();

  test('connection state event reaches onConnectionStateChanged and updates the device', () async {
    final device = Bluebird.deviceForAddress('AA');
    final seen = expectLater(Bluebird.events.onConnectionStateChanged, emits(anything));
    fake.emit(BmConnectionStateEvent(address: 'AA', connectionState: BmConnectionStateEnum.connected));
    await pump();
    expect(device.isConnected, isTrue);
    await seen;
  });

  test('name changed event reaches onNameChanged', () async {
    final seen = expectLater(
      Bluebird.events.onNameChanged,
      emits(isA<OnNameChangedEvent>().having((e) => e.name, 'name', 'Renamed')),
    );
    fake.emit(BmNameChangedEvent(address: 'AA', name: 'Renamed'));
    await seen;
  });

  test('mtu changed event reaches onMtuChanged', () async {
    final seen = expectLater(
      Bluebird.events.onMtuChanged,
      emits(isA<OnMtuChangedEvent>().having((e) => e.mtu, 'mtu', 400)),
    );
    fake.emit(BmMtuChangedEvent(address: 'AA', mtu: 400));
    await seen;
  });

  test('bond state event reaches onBondStateChanged', () async {
    final seen = expectLater(Bluebird.events.onBondStateChanged, emits(anything));
    fake.emit(BmBondStateEvent(address: 'AA', bondState: BmBondStateEnum.bonded));
    await seen;
  });

  test('services reset event reaches onServicesReset', () async {
    final seen = expectLater(Bluebird.events.onServicesReset, emits(anything));
    fake.emit(BmServicesResetEvent(address: 'AA'));
    await seen;
  });

  test('detached-from-engine event stops an active scan', () async {
    await Bluebird.startScan();
    expect(Bluebird.isScanningNow, isTrue);
    fake.emit(BmDetachedFromEngineEvent());
    await pump();
    expect(Bluebird.isScanningNow, isFalse);
  });
}
