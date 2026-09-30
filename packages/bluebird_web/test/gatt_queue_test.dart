import 'dart:async';

import 'package:bluebird_web/src/gatt_queue.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const device = 'device';
  late GattQueue queue;

  setUp(() => queue = GattQueue());

  // An operation starts on the microtask after it is submitted.
  Future<void> started() => Future<void>.delayed(Duration.zero);

  Matcher throwsDisconnected() =>
      throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'device_disconnected'));

  test("runs a device's operations one at a time, in submission order", () async {
    final log = <String>[];
    Future<void> op(int i, int ms) => queue.run(device, () async {
      log.add('start $i');
      await Future<void>.delayed(Duration(milliseconds: ms));
      log.add('end $i');
    });

    await Future.wait([op(1, 30), op(2, 10), op(3, 0)]);

    expect(log, ['start 1', 'end 1', 'start 2', 'end 2', 'start 3', 'end 3']);
  });

  test('devices do not wait on one another', () async {
    final gate = Completer<void>();
    unawaited(queue.run('a', () => gate.future));

    expect(await queue.run('b', () async => 42), 42);
    gate.complete();
  });

  test('a failed operation hands over to the next', () async {
    await expectLater(queue.run(device, () async => throw StateError('boom')), throwsStateError);
    expect(await queue.run(device, () async => 42), 42);
  });

  test('operations queued before a disconnect fail rather than run on the next connection', () async {
    final gate = Completer<void>();
    var ran = false;

    final running = queue.run(device, () => gate.future);
    final queued = expectLater(queue.run(device, () async => ran = true), throwsDisconnected());
    await started();

    queue.disconnected(device);
    gate.complete();

    await running;
    await queued;
    expect(ran, isFalse);
  });

  test("the next connection's operations wait for the one still running at the disconnect", () async {
    final gate = Completer<void>();
    final log = <String>[];

    final running = queue.run(device, () async {
      await gate.future;
      log.add('old');
    });
    await started();
    queue.disconnected(device);
    final next = queue.run(device, () async => log.add('new'));

    await started();
    expect(log, isEmpty);

    gate.complete();
    await Future.wait([running, next]);
    expect(log, ['old', 'new']);
  });

  test('operations submitted after a disconnect run normally', () async {
    queue.disconnected(device);
    expect(await queue.run(device, () async => 42), 42);
  });
}
