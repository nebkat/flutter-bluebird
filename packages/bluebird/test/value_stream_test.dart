import 'dart:async';

import 'package:bluebird/src/utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('StreamControllerReEmit', () {
    test('caches the latest value and re-emits it on listen', () async {
      final s = StreamControllerReEmit<int>(initialValue: 0);
      expect(s.value, 0);

      s.add(1);
      expect(s.value, 1);

      // a late listener still sees the latest value first, then changes
      final events = <int>[];
      final sub = s.stream.listen(events.add);
      await pumpEventQueue();
      expect(events, [1]);

      s.add(2);
      await pumpEventQueue();
      expect(events, [1, 2]);

      await sub.cancel();
      await s.close();
    });

    test('addError forwards errors to listeners', () async {
      final s = StreamControllerReEmit<int>(initialValue: 0);
      Object? captured;
      final sub = s.stream.listen((_) {}, onError: (Object e) => captured = e);
      await pumpEventQueue();

      s.addError(StateError('boom'));
      await pumpEventQueue();
      expect(captured, isStateError);

      await sub.cancel();
      await s.close();
    });
  });

  group('ValueStream', () {
    test('value reads synchronously and listen re-emits it first', () async {
      final ctrl = StreamController<int>.broadcast();
      var current = 1;
      final vs = ValueStream<int>(value: () => current, changes: () => ctrl.stream);

      expect(vs.value, 1);
      expect(vs.isBroadcast, isTrue);

      final events = <int>[];
      final sub = vs.listen(events.add);
      await pumpEventQueue();
      expect(events, [1]); // current value emitted before any change

      current = 2;
      ctrl.add(2);
      await pumpEventQueue();
      expect(events, [1, 2]);

      await sub.cancel();
      await ctrl.close();
    });

    test('changes yields deltas only, without re-emitting the current value', () async {
      final ctrl = StreamController<int>.broadcast();
      final vs = ValueStream<int>(value: () => 0, changes: () => ctrl.stream);

      final deltas = <int>[];
      final sub = vs.changes.listen(deltas.add);
      await pumpEventQueue();
      expect(deltas, isEmpty); // no leading current value

      ctrl.add(5);
      await pumpEventQueue();
      expect(deltas, [5]);

      await sub.cancel();
      await ctrl.close();
    });

    test('map preserves the value view and converts changes', () async {
      final ctrl = StreamController<int>.broadcast();
      var current = 3;
      final vs = ValueStream<int>(value: () => current, changes: () => ctrl.stream);
      final mapped = vs.map((n) => 'v$n');

      expect(mapped.value, 'v3');

      final events = <String>[];
      final sub = mapped.listen(events.add);
      await pumpEventQueue();
      expect(events, ['v3']);

      current = 4;
      ctrl.add(4);
      await pumpEventQueue();
      expect(events, ['v3', 'v4']);

      await sub.cancel();
      await ctrl.close();
    });
  });

  group('AsyncValueStream', () {
    test('value fetches asynchronously and listen emits it first', () async {
      final ctrl = StreamController<int>.broadcast();
      var fetches = 0;
      final avs = AsyncValueStream<int>(
        value: () async {
          fetches++;
          return 100;
        },
        changes: () => ctrl.stream,
      );

      expect(avs.isBroadcast, isTrue);
      expect(await avs.value, 100);
      expect(fetches, 1);

      final events = <int>[];
      final sub = avs.listen(events.add);
      await pumpEventQueue();
      expect(events, [100]); // fetched current value emitted first

      ctrl.add(200);
      await pumpEventQueue();
      expect(events, [100, 200]);

      await sub.cancel();
      await ctrl.close();
    });

    test('changes yields deltas only', () async {
      final ctrl = StreamController<int>.broadcast();
      final avs = AsyncValueStream<int>(value: () async => 0, changes: () => ctrl.stream);

      final deltas = <int>[];
      final sub = avs.changes.listen(deltas.add);
      await pumpEventQueue();
      expect(deltas, isEmpty);

      ctrl.add(9);
      await pumpEventQueue();
      expect(deltas, [9]);

      await sub.cancel();
      await ctrl.close();
    });
  });

  group('newStreamWithInitialValue', () {
    test('broadcast: emits the initial value then forwards source events', () async {
      final ctrl = StreamController<int>.broadcast();
      final stream = ctrl.stream.newStreamWithInitialValue(9);

      final events = <int>[];
      final sub = stream.listen(events.add);
      await pumpEventQueue();
      expect(events, [9]);

      ctrl.add(3);
      await pumpEventQueue();
      expect(events, [9, 3]);

      await sub.cancel();
      await ctrl.close();
    });

    test('single-subscription: forwards events and honors pause/resume', () async {
      final ctrl = StreamController<int>();
      final stream = ctrl.stream.newStreamWithInitialValue(0);

      final events = <int>[];
      final sub = stream.listen(events.add);
      await pumpEventQueue();
      expect(events, [0]);

      ctrl.add(1);
      await pumpEventQueue();
      expect(events, [0, 1]);

      // pausing the returned subscription pauses the source; the event buffers
      sub.pause();
      ctrl.add(2);
      await pumpEventQueue();
      expect(events, [0, 1]);

      sub.resume();
      await pumpEventQueue();
      expect(events, [0, 1, 2]);

      await sub.cancel();
      await ctrl.close();
    });
  });
}
