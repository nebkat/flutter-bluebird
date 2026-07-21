## 0.4.0

- Added the L2CAP channel protocol: `openL2capChannel` / `closeL2capChannel` host methods, the `BmL2capChannelClosedEvent`, and the shared `bluebird/l2cap` binary data channel exposed as `l2capInput` / `l2capWrite` / `l2capDetach`.

## 0.3.0

- `BluetoothConnectionState` gains `connecting` and `disconnecting`, appended so the existing wire indices for `disconnected` / `connected` are preserved. The transient states are synthesized in `package:bluebird`; the natives still emit only the terminal states.

## 0.2.0

- **Breaking:** replaced the `BluebirdPlatform.log(String)` / `logs` string sink with a [`package:logging`](https://pub.dev/packages/logging) `Logger` at `BluebirdPlatform.logger`; added a `logging` dependency.
- **Breaking:** `BluebirdPlatform.setLogLevel` no longer takes a `color` argument.
- **Breaking:** reworked `BluebirdErrorCode` — `gattError`/`cbError` are replaced by `androidError`, `darwinError`, and `attError` (a peer ATT Error Response, carrying the raw one-octet code).

## 0.1.0

- Initial release.
