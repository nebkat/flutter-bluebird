## Unreleased

- Fixed one stuck platform call wedging every later one for the life of the process. The internal platform queue is held for the duration of a call, but a timeout was applied from outside it: the caller was handed a `timeout` error while the call itself stayed in flight, holding the queue with nothing left to release it. A connect to a device that had gone away — CoreBluetooth waits for such a peripheral indefinitely — was enough to take out scanning, connecting and every read for good, recoverable only by restarting the app. The timeout and the adapter-off guard now run inside the queue, so giving up on a call releases it and costs only that one operation.
- Fixed `connect(timeout:)` never timing out. Its own cleanup — the `disconnect` that cancels the timed-out attempt — was an unbounded call queued behind the very connect it was canceling, so the future the caller was waiting on was never completed at all. The cleanup is now bounded, jumps the queue, and no longer runs while the global operation mutex is held.
- Fixed `disconnect(queue: false)` not being able to cancel an in-progress connection attempt, which is what it is for. It skipped the operation queue but not the platform queue, so it could not reach the platform while the connect it was meant to cancel was still on it.
- (Darwin) A connection attempt now ends on its own after 60s even if nothing cancels it, instead of staying outstanding forever. It is a backstop above the 35s default, so it only bites a `connect(timeout:)` longer than 60s, which it caps. Requires `bluebird_darwin` from this release.
- Added `Bluebird.permission`, reporting whether the app may use Bluetooth at all — `granted`, `denied` (refused, and the OS will still ask again), `permanentlyDenied` (only the settings app can change it) or `notDetermined`. Permission and radio power are independent on Android, so neither answered for the other and there was no way to ask about the first. Darwin reads `CBManager.authorization`, which raises no prompt of its own; Web has no app-level permission and reports `granted`. Read it on demand — nothing broadcasts a permission change — and re-read it when the app returns to the foreground.
- Added `Bluebird.androidLocationEnabled`. Android 11 and below treat a BLE scan as a way to derive position and gate it on the system location toggle as well as the location permission; with the toggle off a scan returns nothing at all and reports no error. True from Android 12, where `neverForLocation` retires the requirement, and true on every other platform. Requires `bluebird_android` from this release.

## 0.4.4

- Fixed a scan refused by the platform hanging forever instead of failing. When `startScan` was rejected — the adapter off, the permission denied — the internal advertisement controller was closed without ever having been listened to, so `close()` never completed: no error reached the caller, the stream never ended, `isScanning` stayed `true`, and every later scan was wedged behind `operationInProgress` for the life of the process.
- (Darwin) Fixed every non-`poweredOn` adapter state being reported as `adapterOff`. `unauthorized` now surfaces as `permissionDenied` and `unsupported` as `unsupported`, from `startScan`, `connect`, and the operations failed when the adapter goes away mid-flight. The three call for different things from the user — Control Centre, the settings app, and nothing at all — and were indistinguishable to callers. Requires `bluebird_darwin` 0.4.4.

## 0.4.3

- Fixed a scan outliving the adapter it runs on: `Bluebird.performScan(...)` now also ends when the adapter goes `unauthorized` or `unavailable`, not only `off`/`turningOff`. Authorization can be revoked from the settings app mid-scan, and the adapter can disappear; either leaves the native scan dead while the stream stays open, waiting for advertisements that can never arrive.
- (Android) `bluebird_android` no longer applies the Kotlin Gradle Plugin, so it drops off the "uses plugins that apply KGP" warning list that future Flutter versions will turn into a build failure. Requires `bluebird_android` 0.4.3.

## 0.4.2

- Fixed (Web) a spurious `deviceDisconnected` when a device is disconnected and quickly reconnected: a delayed `gattserverdisconnected` event from the previous connection could tear down the new one. Requires `bluebird_web` 0.4.2.

## 0.4.1

- Fixed (Android) `AdvertisementData.manufacturerData` when an advertisement carries more than one manufacturer specific data structure. Each structure is now keyed by its own company id, instead of being merged into a single blob under the first company id (which leaked later structures' ids into the earlier payload). Requires `bluebird_android` 0.4.1.

## 0.4.0

- Added L2CAP connection-oriented channel support. `device.openL2capChannel(psm, secure: …)` returns a `BluetoothL2CapChannel` — a bidirectional byte stream to the peer (`input` / `write(...)` / `close()`), independent of GATT, on Android (API 29+) and iOS/macOS (unsupported on Web; `secure` is Android-only). Data flows over a dedicated binary channel with backpressure in both directions and does not pass through the global GATT operation queue, so its throughput neither gates nor is gated by characteristic I/O. The channel closes on its own when the peer closes it or the device disconnects.
- **Breaking:** `AdvertisementData.advName` is now `String?`. It is `null` when the advertisement carries no name, rather than being coerced to an empty string. `mergedWith` carries the prior name forward whenever `newer.advName` is `null`.

## 0.3.0

- **Breaking:** `BluetoothConnectionState` now has `connecting` and `disconnecting` in addition to `connected` / `disconnected`. They are synthesized on the Dart side around `device.connect()` / `disconnect()` (the platforms only report the terminal states), so `device.connectionState` drives a connecting/disconnecting spinner directly. `device.isDisconnected` is **removed** — it was ambiguous with the new transient states; use `!device.isConnected`, or `connectionState.value == BluetoothConnectionState.disconnected` for a fully-disconnected device.
- Added an optional `timeout` to `Bluebird.scan(...)`: the scan stops and the stream *completes normally* (not with an error) after the duration, so `Bluebird.scan(timeout: …).accumulate().last` yields the final device list. Also hardened the advertisement feed against add-after-close.

## 0.2.1

- Stopped re-exporting `Level` / `Logger` / `LogRecord` from `package:logging`, which collided with a consumer's own `package:logging` import (`unnecessary_import`). If you configure `Bluebird.logger` directly, add `package:logging` to your `pubspec.yaml`.

## 0.2.0

- **Breaking:** logging now flows through a single [`package:logging`](https://pub.dev/packages/logging) `Logger`, exposed as `Bluebird.logger` (with `Level`, `Logger`, and `LogRecord` re-exported). Nothing is printed by default — attach an `onRecord` listener, or call `Bluebird.configureLoggerPrinting()` for a console one-liner. The previous string log stream and default `print` output have been removed.
- **Breaking:** renamed `Bluebird.setLogLevel` to `setPlatformLogLevel` (and `logLevel` to `platformLogLevel`) and removed its `color` argument. It now sets only the native logcat / os_log verbosity; Dart-side output is filtered with `Bluebird.logger.level`. Records are path-scoped (`[remoteId][service][characteristic] …`), with platform-channel call tracing at `Level.FINEST`.
- **Breaking:** reworked error codes around ATT protocol errors. `BluebirdErrorCode.gattError`/`cbError` are replaced by `androidError`/`darwinError` (local stack or link failures) and `attError` (the peer answered with an ATT Error Response). A new `BluetoothAttException` — with `AttError` constants and `attError` — surfaces peer rejections with their raw one-octet code, uniformly across platforms.
- `characteristic.notifications` and `characteristic.values` are now broadcast streams: several listeners share one notify enable, and notify is released when the last idle listener (e.g. a mobx `ObservableStream` or `StreamBuilder`) cancels.
- Fixed Web/WASM compatibility: platform detection no longer pulls `dart:io` into the web build (it is now behind a conditional import), so the package is Web- and WASM-compatible.

## 0.1.0

- Initial release.
