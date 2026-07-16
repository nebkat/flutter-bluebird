import 'package:bluebird/bluebird.dart';
import 'package:bluebird_platform_interface/bluebird_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_platform.dart';

void main() {
  late FakePlatform fake;

  setUp(() {
    fake = FakePlatform();
    FakePlatform.install(fake);
  });

  test('isSupported and adapterName delegate to the platform', () async {
    expect(await Bluebird.isSupported, isTrue);
    expect(await Bluebird.adapterName, 'FakeAdapter');
  });

  test('turnOn completes once the adapter is on', () async {
    await Bluebird.turnOn(); // fake adapter already reports on
    expect(fake.calls, contains('turnOn'));
  });

  test('turnOn throws userRejected when the user declines', () {
    fake.stubs['turnOn'] = () => false;
    expect(
      () => Bluebird.turnOn(),
      throwsA(isA<BluebirdException>().having((e) => e.code, 'code', BluebirdErrorCode.userRejected)),
    );
  });

  test('systemDevices maps platform devices and carries platform names', () async {
    fake.systemDevices = [BmBluetoothDevice(address: 'AA', platformName: 'Sensor')];
    final devices = await Bluebird.systemDevices([Uuid('180f')]);
    expect(devices.single.remoteId, 'AA');
    expect(devices.single.platformName, 'Sensor');
  });

  test('connectedDevices reflects per-device connection state', () async {
    final device = Bluebird.deviceForAddress('AA');
    expect(Bluebird.connectedDevices, isEmpty);
    device.applyEvent(OnConnectionStateChangedEvent(device, BluetoothConnectionState.connected, null));
    expect(Bluebird.connectedDevices, [device]);
  });

  test('setPlatformLogLevel records the level', () async {
    await Bluebird.setPlatformLogLevel(LogLevel.warning);
    expect(Bluebird.platformLogLevel, LogLevel.warning);
    expect(fake.calls, contains('setLogLevel'));
  });

  test('setOptions delegates (darwin only)', () async {
    // setOptions is darwin-only; pretend the host is macOS so this passes
    // regardless of the CI runner's OS (`System.current` is a mutable static).
    final realSystem = System.current;
    System.current = System.macos;
    addTearDown(() => System.current = realSystem);
    await Bluebird.setOptions(showPowerAlert: false);
    expect(fake.calls, contains('setOptions'));
  });
}
