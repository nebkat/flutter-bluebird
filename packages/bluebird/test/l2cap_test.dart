import 'dart:typed_data';

import 'package:bluebird/bluebird.dart';
import 'package:bluebird_platform_interface/bluebird_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_platform.dart';

void main() {
  late FakePlatform fake;
  late BluetoothDevice device;
  final realSystem = System.current;

  setUp(() {
    System.current = System.android;
    fake = FakePlatform();
    FakePlatform.install(fake);
    device = Bluebird.deviceForAddress('AA:BB:CC:DD:EE:FF');
  });

  tearDown(() => System.current = realSystem);

  Future<BluetoothL2CapChannel> openConnected({int psm = 0x80, bool secure = true}) async {
    await device.connect();
    return device.openL2capChannel(psm, secure: secure);
  }

  test('openL2capChannel delegates to the platform and returns a channel', () async {
    final channel = await openConnected(psm: 0x81, secure: false);

    expect(fake.calls, contains('openL2capChannel'));
    expect(fake.lastL2capPsm, 0x81);
    expect(fake.lastL2capSecure, isFalse);
    expect(channel.psm, 0x81);
    expect(channel.device, device);
    expect(channel.isClosed, isFalse);
  });

  test('open on a disconnected device throws deviceDisconnected', () {
    expect(
      () => device.openL2capChannel(0x80),
      throwsA(isA<BluebirdException>().having((e) => e.code, 'code', BluebirdErrorCode.deviceDisconnected)),
    );
  });

  test('open is rejected on platforms without L2CAP (web)', () async {
    System.current = System.web;
    expect(
      () => device.openL2capChannel(0x80),
      throwsA(isA<BluebirdException>().having((e) => e.code, 'code', BluebirdErrorCode.platform)),
    );
  });

  test('write delegates to the platform data channel', () async {
    final channel = await openConnected();
    final data = Uint8List.fromList([1, 2, 3, 4]);

    await channel.write(data);

    expect(fake.l2capWrites[channel.channelId], [data]);
  });

  test('input exposes the platform inbound stream', () async {
    final channel = await openConnected();

    final received = <List<int>>[];
    final sub = channel.input.listen(received.add);
    fake.l2capInboundControllers[channel.channelId]!.add(Uint8List.fromList([9, 8, 7]));
    await Future<void>.delayed(Duration.zero);

    expect(received, [
      [9, 8, 7],
    ]);
    await sub.cancel();
  });

  test('close() delegates and marks the channel closed', () async {
    final channel = await openConnected();

    await channel.close();

    expect(fake.calls, contains('closeL2capChannel'));
    expect(fake.l2capDetached, contains(channel.channelId));
    expect(channel.isClosed, isTrue);
  });

  test('write after close throws', () async {
    final channel = await openConnected();
    await channel.close();

    expect(
      () => channel.write(Uint8List.fromList([0])),
      throwsA(isA<BluebirdException>().having((e) => e.code, 'code', BluebirdErrorCode.deviceDisconnected)),
    );
  });

  test('an unsolicited close event closes the channel and detaches it', () async {
    final channel = await openConnected();

    fake.emit(
      BmL2capChannelClosedEvent(
        channelId: channel.channelId,
        address: device.remoteId,
        errorCode: 'device_disconnected',
        errorString: 'device is disconnected',
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(channel.isClosed, isTrue);
    expect(fake.l2capDetached, contains(channel.channelId));
    // it was already torn down, so an explicit close() does not re-invoke the platform
    await channel.close();
    expect(fake.calls, isNot(contains('closeL2capChannel')));
  });
}
