import 'package:bluebird/bluebird.dart';
import 'package:bluebird/mock.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_platform.dart';

/// The opt-in `package:bluebird/mock.dart` wrapper must forward to the static
/// [Bluebird] API. This also fails to compile if the wrapped API drifts.
void main() {
  late FakePlatform fake;
  final bluebird = BluebirdMockable();

  setUp(() {
    fake = FakePlatform();
    FakePlatform.install(fake);
  });

  test('forwards simple getters/methods to Bluebird', () async {
    expect(await bluebird.isSupported, isTrue);
    expect(await bluebird.adapterName, 'FakeAdapter');

    await bluebird.setLogLevel(LogLevel.warning);
    expect(bluebird.logLevel, LogLevel.warning);
    expect(fake.calls, contains('setLogLevel'));
  });

  test('scan forwards and is observable via isScanning', () async {
    expect(bluebird.isScanning.value, isFalse);
    final sub = bluebird.scan().listen((_) {});
    await pumpEventQueue();
    expect(bluebird.isScanning.value, isTrue);
    await sub.cancel();
  });
}
