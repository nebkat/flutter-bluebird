import 'dart:async';

import 'package:bluebird/bluebird.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_platform.dart';

void main() {
  late FakePlatform fake;

  setUp(() {
    fake = FakePlatform();
    FakePlatform.install(fake);
  });

  test('cancelling a scan while startScan is in flight releases the scan guard', () async {
    fake.stubs['startScan'] = () => Future<void>.delayed(const Duration(milliseconds: 100));

    final subscription = Bluebird.performScan().listen((_) {});
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await subscription.cancel();

    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(Bluebird.isScanning.value, isFalse);
    expect(fake.calls, contains('stopScan'));
  });

  // A widget test is the only place most consumers can exercise a scan, and there the
  // teardown used to wedge: `flutter_test`'s fake async does not complete a broadcast
  // subscription's cancel future between pumps, so a `_stop` that awaited those never
  // reached `stopScan` and never released the scan guard. Everything after it in the
  // same test was then refused as a scan already in progress.
  testWidgets('cancelling a scan settles under fake async', (tester) async {
    final sub = Bluebird.performScan().listen((_) {});
    await tester.pump();

    var cancelled = false;
    unawaited(sub.cancel().then((_) => cancelled = true));
    for (var i = 0; i < 10 && !cancelled; i++) {
      await tester.pump();
    }

    expect(cancelled, isTrue, reason: 'the cancel completes rather than hanging on its own teardown');
    expect(Bluebird.isScanning.value, isFalse);
    expect(fake.calls, contains('stopScan'));
  });

  testWidgets('a scan can be started again in the same widget test', (tester) async {
    final first = Bluebird.performScan().listen((_) {});
    await tester.pump();
    unawaited(first.cancel());
    for (var i = 0; i < 10 && Bluebird.isScanning.value; i++) {
      await tester.pump();
    }

    Object? error;
    final second = Bluebird.performScan().listen((_) {}, onError: (Object e) => error = e);
    for (var i = 0; i < 10; i++) {
      await tester.pump();
    }

    expect(error, isNull, reason: 'the first scan let the guard go, so this one is not refused');
    expect(Bluebird.isScanning.value, isTrue);
    unawaited(second.cancel());
  });
}
