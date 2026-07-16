## 0.2.0

- **Breaking:** logging now flows through a single [`package:logging`](https://pub.dev/packages/logging) `Logger`, exposed as `Bluebird.logger` (with `Level`, `Logger`, and `LogRecord` re-exported). Nothing is printed by default — attach an `onRecord` listener, or call `Bluebird.configureLoggerPrinting()` for a console one-liner. The previous string log stream and default `print` output have been removed.
- **Breaking:** renamed `Bluebird.setLogLevel` to `setPlatformLogLevel` (and `logLevel` to `platformLogLevel`) and removed its `color` argument. It now sets only the native logcat / os_log verbosity; Dart-side output is filtered with `Bluebird.logger.level`. Records are path-scoped (`[remoteId][service][characteristic] …`), with platform-channel call tracing at `Level.FINEST`.
- **Breaking:** reworked error codes around ATT protocol errors. `BluebirdErrorCode.gattError`/`cbError` are replaced by `androidError`/`darwinError` (local stack or link failures) and `attError` (the peer answered with an ATT Error Response). A new `BluetoothAttException` — with `AttError` constants and `attError` — surfaces peer rejections with their raw one-octet code, uniformly across platforms.
- `characteristic.notifications` and `characteristic.values` are now broadcast streams: several listeners share one notify enable, and notify is released when the last idle listener (e.g. a mobx `ObservableStream` or `StreamBuilder`) cancels.

## 0.1.0

- Initial release.
