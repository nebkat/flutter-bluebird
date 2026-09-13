// adapterState on Android with the scan permission refused. Put the example
// app into the refused-without-a-dialog state first:
//   adb shell pm revoke com.lib.bluebird_example android.permission.BLUETOOTH_SCAN
//   adb shell pm set-permission-flags com.lib.bluebird_example android.permission.BLUETOOTH_SCAN user-fixed
// and undo it afterwards with `pm grant` and `pm clear-permission-flags`.
// Run with:
//   flutter test integration_test/readiness_test.dart -d <android device>

import 'dart:io';

import 'package:bluebird/bluebird.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('a refused scan permission reads unauthorized, but only once refused', () async {
    if (!Platform.isAndroid) return markTestSkipped('Android only');

    // never asked in this process: not a blocker, so the radio alone
    expect(await Bluebird.adapterState.value, BluetoothAdapterState.on);

    final change = Bluebird.adapterState.changes.first;
    try {
      await Bluebird.performScan(timeout: const Duration(seconds: 2)).toList();
      return markTestSkipped('BLUETOOTH_SCAN is granted; revoke it first (see the file header)');
    } on BluebirdException catch (e) {
      expect(e.code, BluebirdErrorCode.permissionDenied);
    }

    // the refusal is pushed, and read back
    expect(await change.timeout(const Duration(seconds: 5)), BluetoothAdapterState.unauthorized);
    expect(await Bluebird.adapterState.value, BluetoothAdapterState.unauthorized);
  });
}
