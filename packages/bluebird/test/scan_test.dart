import 'package:bluebird/bluebird.dart';
import 'package:bluebird_platform_interface/bluebird_platform_interface.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';

import 'fake_platform.dart';
import 'protos.dart';

void main() {
  late FakePlatform fake;

  setUp(() {
    fake = FakePlatform();
    FakePlatform.install(fake);
  });

  test('advertisements accumulate and de-duplicate by address', () async {
    await Bluebird.startScan();
    expect(fake.calls, contains('startScan'));

    fake.emit(BmScanAdvertisementsEvent(advertisements: [bmAdv('AA', advName: 'one'), bmAdv('BB', advName: 'two')]));
    await pumpEventQueue();
    expect(Bluebird.lastScanResults.map((r) => r.address), unorderedEquals(['AA', 'BB']));

    // a fresh advertisement for AA updates in place, not appends
    fake.emit(BmScanAdvertisementsEvent(advertisements: [bmAdv('AA', advName: 'one-again', rssi: -40)]));
    await pumpEventQueue();
    expect(Bluebird.lastScanResults, hasLength(2));
    expect(Bluebird.lastScanResults.firstWhere((r) => r.address == 'AA').rssi, -40);

    await Bluebird.stopScan();
    expect(Bluebird.isScanningNow, isFalse);
  });

  test('scans with filters applied', () async {
    await Bluebird.startScan(
      withServices: [Uuid('180f')],
      withMsd: [MsdFilter(0x02e5, data: [1], mask: [0xff])],
      withServiceData: [ServiceDataFilter(Uuid('180a'), data: [2])],
      withNames: ['dev'],
    );
    expect(fake.calls, contains('startScan'));
    await Bluebird.stopScan();
  });

  test('oneByOne streams each advertisement individually', () async {
    final seen = <String>[];
    final sub = Bluebird.scanResults.listen((r) {
      if (r.isNotEmpty) seen.add(r.single.address);
    });
    await Bluebird.startScan(oneByOne: true);
    fake.emit(BmScanAdvertisementsEvent(advertisements: [bmAdv('AA'), bmAdv('BB')]));
    await pumpEventQueue();
    expect(seen, ['AA', 'BB']);
    await sub.cancel();
  });

  test('a timeout stops the scan automatically', () async {
    await Bluebird.startScan(timeout: const Duration(milliseconds: 50));
    expect(Bluebird.isScanningNow, isTrue);
    await Future.delayed(const Duration(milliseconds: 150));
    expect(Bluebird.isScanningNow, isFalse);
    expect(fake.calls, contains('stopScan'));
  });

  test('a scan failure surfaces as an error and stops scanning', () async {
    await Bluebird.startScan();
    final error = expectLater(Bluebird.scanResults, emitsThrough(emitsError(isA<BluebirdException>())));
    fake.emit(BmScanFailedEvent(errorCode: 2, errorString: 'bluetooth off'));
    await error;
    expect(Bluebird.isScanningNow, isFalse);
  });

  test('platform errors map to BluebirdException by wire code', () async {
    fake.stubs['isSupported'] = () => throw PlatformException(code: 'adapter_off', message: 'off');
    await expectLater(
      Bluebird.isSupported,
      throwsA(isA<BluebirdException>().having((e) => e.code, 'code', BluebirdErrorCode.adapterOff)),
    );

    fake.stubs['isSupported'] = () => throw PlatformException(code: 'something_unmapped');
    await expectLater(
      Bluebird.isSupported,
      throwsA(isA<BluebirdException>().having((e) => e.code, 'code', BluebirdErrorCode.platform)),
    );
  });

  test('adapter state reflects platform events', () async {
    fake.adapterState = BmAdapterStateEnum.off;
    expect(await Bluebird.adapterState.first, BluetoothAdapterState.off);

    fake.emit(BmAdapterStateEvent(adapterState: BmAdapterStateEnum.on));
    expect(await Bluebird.adapterState.first, BluetoothAdapterState.on);
  });
}
