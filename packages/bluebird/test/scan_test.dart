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

  test('scan() emits each advertisement individually', () async {
    final seen = <String>[];
    final sub = Bluebird.scan().listen((r) => seen.add(r.address));
    await pumpEventQueue();
    expect(fake.calls, contains('startScan'));
    expect(Bluebird.isScanning.value, isTrue);

    fake.emit(BmScanAdvertisementEvent(advertisement: bmAdv('AA')));
    fake.emit(BmScanAdvertisementEvent(advertisement: bmAdv('BB')));
    await pumpEventQueue();
    expect(seen, ['AA', 'BB']);

    await sub.cancel();
    await pumpEventQueue();
    expect(Bluebird.isScanning.value, isFalse);
    expect(fake.calls, contains('stopScan'));
  });

  test('accumulate() collects advertisements into a de-duplicated list', () async {
    var latest = <ScanResult>[];
    final sub = Bluebird.scan().accumulate().listen((list) => latest = list);
    await pumpEventQueue();

    fake.emit(BmScanAdvertisementEvent(advertisement: bmAdv('AA', advName: 'one')));
    fake.emit(BmScanAdvertisementEvent(advertisement: bmAdv('BB', advName: 'two')));
    await pumpEventQueue();
    expect(latest.map((r) => r.address), unorderedEquals(['AA', 'BB']));

    // a fresh advertisement for AA updates in place, not appends
    fake.emit(BmScanAdvertisementEvent(advertisement: bmAdv('AA', advName: 'one-again', rssi: -40)));
    await pumpEventQueue();
    expect(latest, hasLength(2));
    expect(latest.firstWhere((r) => r.address == 'AA').rssi, -40);

    await sub.cancel();
  });

  test('scans with filters applied', () async {
    final sub = Bluebird.scan(
      withServices: [Uuid('180f')],
      withMsd: [
        MsdFilter(0x02e5, data: [1], mask: [0xff]),
      ],
      withServiceData: [
        ServiceDataFilter(Uuid('180a'), data: [2]),
      ],
      withNames: ['dev'],
    ).listen((_) {});
    await pumpEventQueue();
    expect(fake.calls, contains('startScan'));
    await sub.cancel();
  });

  test('cancelling the subscription stops the scan', () async {
    final sub = Bluebird.scan().listen((_) {});
    await pumpEventQueue();
    expect(Bluebird.isScanning.value, isTrue);

    await sub.cancel();
    await pumpEventQueue();
    expect(Bluebird.isScanning.value, isFalse);
    expect(fake.calls, contains('stopScan'));
  });

  test('scan(timeout:) stops the scan and completes the stream normally', () async {
    final seen = <String>[];
    var done = false;
    final sub = Bluebird.scan(
      timeout: const Duration(milliseconds: 50),
    ).listen((r) => seen.add(r.address), onDone: () => done = true);
    await pumpEventQueue();
    expect(Bluebird.isScanning.value, isTrue);

    fake.emit(BmScanAdvertisementEvent(advertisement: bmAdv('AA')));
    await pumpEventQueue();
    expect(seen, ['AA']);

    // let the timeout fire
    await Future<void>.delayed(const Duration(milliseconds: 80));
    await pumpEventQueue();

    expect(done, isTrue); // completed normally (onDone), not an error
    expect(Bluebird.isScanning.value, isFalse); // guard released
    expect(fake.calls, contains('stopScan')); // platform told to stop (scan was alive)
    await sub.cancel();
  });

  test('scan(timeout:).accumulate().last yields the final device list', () async {
    final future = Bluebird.scan(timeout: const Duration(milliseconds: 50)).accumulate().last;
    await pumpEventQueue();

    fake.emit(BmScanAdvertisementEvent(advertisement: bmAdv('AA')));
    fake.emit(BmScanAdvertisementEvent(advertisement: bmAdv('BB')));

    final list = await future; // resolves when the timeout completes the stream
    expect(list.map((r) => r.address), unorderedEquals(['AA', 'BB']));
    expect(Bluebird.isScanning.value, isFalse);
  });

  test('a second concurrent scan throws operationInProgress', () async {
    final sub = Bluebird.scan().listen((_) {});
    await pumpEventQueue();
    expect(Bluebird.isScanning.value, isTrue);

    await expectLater(
      Bluebird.scan().first,
      throwsA(isA<BluebirdException>().having((e) => e.code, 'code', BluebirdErrorCode.operationInProgress)),
    );
    await sub.cancel();
  });

  test('a scan failure surfaces as an error and stops scanning', () async {
    final errors = <Object>[];
    final sub = Bluebird.scan().listen((_) {}, onError: errors.add);
    await pumpEventQueue();

    fake.emit(BmScanFailedEvent(errorCode: 2, errorString: 'bluetooth off'));
    await pumpEventQueue();
    expect(errors.single, isA<BluebirdException>());
    expect(Bluebird.isScanning.value, isFalse);
    await sub.cancel();
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

  test('att_error maps to a BluetoothAttException carrying the spec code', () async {
    fake.stubs['isSupported'] = () => throw PlatformException(code: 'att_error', message: 'nope', details: 3);
    await expectLater(
      Bluebird.isSupported,
      throwsA(
        isA<BluetoothAttException>()
            .having((e) => e.code, 'code', BluebirdErrorCode.attError)
            .having((e) => e.attError, 'attError', AttError.writeNotPermitted),
      ),
    );

    // application-range codes (0x80–0x9F) flow through unchanged — the Dart side
    // never range-restricts; the platforms decide what is spec vs platform
    fake.stubs['isSupported'] = () => throw PlatformException(code: 'att_error', details: 0x82);
    await expectLater(
      Bluebird.isSupported,
      throwsA(
        isA<BluetoothAttException>()
            .having((e) => e.attError, 'attError', 0x82)
            .having((e) => e.appErrorZeroIndexed, 'appErrorZeroIndexed', 2),
      ),
    );

    // a core spec code is not in the application range → null
    fake.stubs['isSupported'] = () => throw PlatformException(code: 'att_error', details: AttError.writeNotPermitted);
    await expectLater(
      Bluebird.isSupported,
      throwsA(isA<BluetoothAttException>().having((e) => e.appErrorZeroIndexed, 'appErrorZeroIndexed', isNull)),
    );

    // a platform failure (Android stack / CoreBluetooth CBError) is a plain
    // BluebirdException with no attError
    fake.stubs['isSupported'] = () => throw PlatformException(code: 'android_error', message: 'boom', details: 257);
    await expectLater(
      Bluebird.isSupported,
      throwsA(
        isA<BluebirdException>()
            .having((e) => e, 'not att', isNot(isA<BluetoothAttException>()))
            .having((e) => e.attError, 'attError', isNull),
      ),
    );
  });

  test('adapter state reflects platform events', () async {
    fake.adapterState = BluetoothAdapterState.off;
    expect(await Bluebird.adapterState.first, BluetoothAdapterState.off);

    fake.emit(BmAdapterStateEvent(adapterState: BluetoothAdapterState.on));
    expect(await Bluebird.adapterState.first, BluetoothAdapterState.on);
  });

  test('adapterState is an AsyncValueStream: .value fetches, .changes is deltas-only', () async {
    fake.adapterState = BluetoothAdapterState.off;

    // .value fetches the current state from the platform (adapter events fire
    // only on changes, so the current state must be asked for)
    expect(await Bluebird.adapterState.value, BluetoothAdapterState.off);

    // .changes emits subsequent changes only — no leading current value
    final deltas = expectLater(Bluebird.adapterState.changes, emits(BluetoothAdapterState.on));
    fake.emit(BmAdapterStateEvent(adapterState: BluetoothAdapterState.on));
    await deltas;

    expect(await Bluebird.adapterState.value, BluetoothAdapterState.on);
  });

  test('adapterReady completes immediately when the adapter is already on', () async {
    fake.adapterState = BluetoothAdapterState.on;
    await Bluebird.adapterReady(); // completes without hanging or throwing
  });

  test('adapterReady waits until the adapter turns on', () async {
    fake.adapterState = BluetoothAdapterState.off;
    final ready = Bluebird.adapterReady();
    await pumpEventQueue(); // subscribe and fetch the current (off) state

    fake.emit(BmAdapterStateEvent(adapterState: BluetoothAdapterState.on));
    await ready; // now resolves
  });

  test('adapterReady throws permissionDenied when unauthorized', () async {
    fake.adapterState = BluetoothAdapterState.unauthorized;
    await expectLater(
      Bluebird.adapterReady(),
      throwsA(isA<BluebirdException>().having((e) => e.code, 'code', BluebirdErrorCode.permissionDenied)),
    );
  });

  test('adapterReady throws unsupported when unavailable', () async {
    fake.adapterState = BluetoothAdapterState.unavailable;
    await expectLater(
      Bluebird.adapterReady(),
      throwsA(isA<BluebirdException>().having((e) => e.code, 'code', BluebirdErrorCode.unsupported)),
    );
  });

  test('adapterReady times out while the adapter stays off', () async {
    fake.adapterState = BluetoothAdapterState.off;
    await expectLater(
      Bluebird.adapterReady(timeout: const Duration(milliseconds: 50)),
      throwsA(isA<BluebirdException>().having((e) => e.code, 'code', BluebirdErrorCode.timeout)),
    );
  });
}
