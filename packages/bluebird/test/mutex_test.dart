import 'package:bluebird/src/utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Mutex', () {
    test('protect serializes async closures', () async {
      final m = Mutex();
      final log = <String>[];
      await Future.wait([
        m.protect(() async {
          log.add('A start');
          await Future.delayed(const Duration(milliseconds: 50));
          log.add('A end');
        }),
        m.protect(() async {
          log.add('B start');
          await Future.delayed(const Duration(milliseconds: 10));
          log.add('B end');
        }),
      ]);
      expect(log, ['A start', 'A end', 'B start', 'B end']);
    });

    test('protect releases the mutex when the closure throws', () async {
      final m = Mutex();
      await expectLater(m.protect(() async => throw StateError('boom')), throwsStateError);
      // if the mutex leaked, this would never complete
      expect(await m.protect(() async => 42), 42);
    });

    test('protect executes in take() order', () async {
      final m = Mutex();
      final order = <int>[];
      await Future.wait([for (var i = 0; i < 5; i++) m.protect(() async => order.add(i))]);
      expect(order, [0, 1, 2, 3, 4]);
    });
  });
}
