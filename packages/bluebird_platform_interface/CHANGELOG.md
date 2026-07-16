## Unreleased

- **Breaking:** replaced the `BluebirdPlatform.log(String)` / `logs` string sink with a [`package:logging`](https://pub.dev/packages/logging) `Logger` at `BluebirdPlatform.logger`; added a `logging` dependency.
- **Breaking:** `BluebirdPlatform.setLogLevel` no longer takes a `color` argument.
- **Breaking:** reworked `BluebirdErrorCode` — `gattError`/`cbError` are replaced by `androidError`, `darwinError`, and `attError` (a peer ATT Error Response, carrying the raw one-octet code).

## 0.1.0

- Initial release.
