## Unreleased

- Platform method-channel tracing now goes to `BluebirdPlatform.logger` (at `Level.FINEST`); `setLogLevel` no longer takes a `color` argument.
- Surface a peer's ATT Error Response (`CBATTErrorDomain`) as `attError` (with the raw ATT code), distinct from other CoreBluetooth failures (`darwinError`).

## 0.1.0

- Initial release.
