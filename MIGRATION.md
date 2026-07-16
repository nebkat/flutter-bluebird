# Migrating from flutter_blue_plus

Bluebird began as a rework of [flutter_blue_plus], so the shape of a session is
unchanged — scan, connect, discover, read/write/subscribe — and most of
`BluetoothDevice`, `BluetoothService`, and `BluetoothCharacteristic` works the
same. This guide covers what changed.

[flutter_blue_plus]: https://pub.dev/packages/flutter_blue_plus

## Package

```yaml
dependencies:
  bluebird: ^0.1.0   # was: flutter_blue_plus
```

```dart
import 'package:bluebird/bluebird.dart';   // was: package:flutter_blue_plus/flutter_blue_plus.dart
```

## Renames

| flutter_blue_plus | bluebird |
| --- | --- |
| `FlutterBluePlus` | `Bluebird` |
| `Guid` | `Uuid` |
| `FlutterBluePlusException` | `BluebirdException` |
| `FbpErrorCode` | `BluebirdErrorCode` |

`Guid('180d')` becomes `Uuid('180d')` (same 16-/32-/128-bit forms). Anywhere you
passed `List<Guid>` — e.g. `withServices` — now takes `List<Uuid>`.

## Scanning

Scanning is now a single stream you listen to, rather than a start/stop pair
plus a separate results stream. `scan()` starts when you listen and stops when
you cancel.

```dart
// flutter_blue_plus
var sub = FlutterBluePlus.scanResults.listen((results) { ... });
await FlutterBluePlus.startScan(withServices: [Guid('180d')], timeout: Duration(seconds: 15));
await FlutterBluePlus.stopScan();

// bluebird
final sub = Bluebird.scan(withServices: [Uuid('180d')]).accumulate().listen((results) { ... });
// ... later, to stop scanning:
await sub.cancel();
```

| flutter_blue_plus | bluebird |
| --- | --- |
| `FlutterBluePlus.startScan(...)` + `FlutterBluePlus.stopScan()` | listen to / cancel `Bluebird.scan(...)` |
| `FlutterBluePlus.scanResults` (growing device list) | `Bluebird.scan(...).accumulate()` |
| `FlutterBluePlus.onScanResults` | `Bluebird.scan(...).accumulate()` (a fresh `scan()` never replays a previous scan) |
| `oneByOne: true` / individual advertisements | `Bluebird.scan(...)` — the base stream yields one `ScanResult` at a time |
| `removeIfGone:` on `startScan` | `Bluebird.scan(...).accumulate(removeIfGone: ...)` |
| `FlutterBluePlus.isScanningNow` | `Bluebird.isScanning.value` |
| `FlutterBluePlus.isScanning` (`Stream<bool>`) | `Bluebird.isScanning` (`ValueStream<bool>`; listen the same way) |

Scan filter arguments (`withServices`, `withNames`, `withKeywords`, `withMsd`,
`withServiceData`, `androidScanMode`, `continuousUpdates`, …) are unchanged apart
from `Guid` → `Uuid`.

## Adapter state

```dart
// flutter_blue_plus
var now = FlutterBluePlus.adapterStateNow;

// bluebird
var now = Bluebird.adapterState.value;
```

`Bluebird.adapterState` is still a stream you can `listen` to; it just also
exposes the current value via `.value`. The `BluetoothAdapterState`,
`BluetoothConnectionState`, and `BluetoothBondState` enums keep the same names
and values.

## Characteristic values & notifications

flutter_blue_plus separated "enable notify" from "receive values" and cached the
last value. In bluebird, **listening to `notifications` enables notify/indicate**,
and `read()` returns the value directly — there is no `lastValueStream`.

```dart
// flutter_blue_plus
await c.setNotifyValue(true);
c.onValueReceived.listen((value) { ... });   // or c.lastValueStream
final value = await c.read();                // then read from c.lastValue / onValueReceived

// bluebird
final sub = c.notifications.listen((value) { ... });   // listening turns notify on
await sub.cancel();                                     // cancelling turns it off
final value = await c.read();                           // read() returns the value
```

| flutter_blue_plus | bluebird |
| --- | --- |
| `c.setNotifyValue(true)` + `c.onValueReceived` / `c.lastValueStream` | `c.notifications.listen(...)` |
| `c.setNotifyValue(false)` | cancel the `notifications` subscription |
| `c.lastValue` | not retained — keep the value from `read()` or the latest notification |
| `c.read()` (then read `lastValue`) | `c.read()` returns the value |
| `c.isNotifying` | track your own subscription, or use `c.notificationsPassive` to observe without enabling |

Descriptors work the same way; `write(value, withoutResponse:, allowLongWrite:)`
is unchanged.

## Errors

```dart
try {
  await c.read();
} on BluebirdException catch (e) {          // was: FlutterBluePlusException
  if (e.code == BluebirdErrorCode.deviceDisconnected) { ... }
}
```

## Logging

flutter_blue_plus had a single `setLogLevel` that also drove console output. In
bluebird these are two separate concerns:

- **`Bluebird.logger`** — a [`package:logging`](https://pub.dev/packages/logging)
  `Logger` carrying all Dart-side logs. It is silent by default; attach your own
  listener and pick a level (nothing is printed unless you do):

  ```dart
  Bluebird.logger.onRecord.listen((r) => debugPrint('${r.level.name} ${r.message}'));
  Bluebird.logger.level = Level.INFO;
  ```

- **`Bluebird.setPlatformLogLevel(LogLevel.verbose)`** — the native/platform log
  verbosity (Android logcat / Apple os_log) only. This replaces `setLogLevel`; the
  old `color:` argument is gone. (Dart-side call tracing is separate — it logs to
  `Bluebird.logger` at `Level.FINEST`.)

| flutter_blue_plus | bluebird |
| --- | --- |
| `FlutterBluePlus.setLogLevel(level, color: …)` | `Bluebird.setPlatformLogLevel(level)` |
| console `print` output (on by default) | attach `Bluebird.logger.onRecord.listen(...)` (off by default) |

## Other differences

- **`device.connect()`** no longer takes `autoConnect`; it's `connect({timeout, mtu})`.
- **`FlutterBluePlus.events`** is now **`Bluebird.events`** (same event classes).
- Everything else on `BluetoothDevice` — `disconnect()`, `discoverServices()`,
  `readRssi()`, `requestMtu()`, `connectionState`, `mtu`, `bondState`,
  `createBond()`, `removeBond()`, `clearGattCache()`, `setPreferredPhy()`,
  `requestConnectionPriority()` — and `Bluebird.connectedDevices`,
  `systemDevices()`, `bondedDevices`, `turnOn()`, `setOptions()`,
  `isSupported` keep the same names.
