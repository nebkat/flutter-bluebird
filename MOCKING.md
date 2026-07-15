# Mocking guide

`Bluebird`'s API is a set of static methods, so it can't be mocked directly.
Bluebird ships an instance wrapper, `BluebirdMockable`, for exactly this — depend
on it in your app instead of calling `Bluebird` directly, and mock it in tests.

It lives in a separate library that is **not** exported by
`package:bluebird/bluebird.dart`, so it is only compiled into apps that import it:

```dart
import 'package:bluebird/mock.dart';
```

`BluebirdMockable` forwards every call to the matching `Bluebird` static
(`scan`, `adapterState`, `isScanning`, `connectedDevices`, `systemDevices`,
`turnOn`, `getPhySupport`, …).

## Inject the wrapper

Pass a `BluebirdMockable` instance through your app (constructor, provider, DI, …)
instead of touching `Bluebird` directly, so tests can substitute a mock:

```dart
import 'package:bluebird/mock.dart';

class MyApp extends StatelessWidget {
  MyApp({super.key});

  final BluebirdMockable bluebird = BluebirdMockable();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: ScanScreen(bluebird: bluebird),
    );
  }
}
```

Within your widgets, replace direct `Bluebird` calls with the injected instance:

- `Bluebird.scan(...)` → `bluebird.scan(...)`
- `Bluebird.isScanning` → `bluebird.isScanning`
- `Bluebird.adapterState` → `bluebird.adapterState`

## Mock it in tests

Using e.g. [mocktail](https://pub.dev/packages/mocktail) or
[Mockito](https://pub.dev/packages/mockito), create a mock of `BluebirdMockable`,
stub the methods your test exercises, and inject it in place of the real one:

```dart
import 'package:bluebird/mock.dart';
import 'package:mocktail/mocktail.dart';

class MockBluebird extends Mock implements BluebirdMockable {}

// in a test:
final bluebird = MockBluebird();
when(() => bluebird.isScanning).thenReturn(/* your fake ValueStream */);
await tester.pumpWidget(MaterialApp(home: ScanScreen(bluebird: bluebird)));
```

If `BluebirdMockable` is missing a call you use, subclass it and add it — every
member is a one-line forward to `Bluebird`.
