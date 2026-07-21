## 0.4.0

- Added L2CAP connection-oriented channel support (`BluetoothDevice.createL2capChannel`, Android 10 / API 29+).

## 0.3.0

- Regenerated for the `BluetoothConnectionState` `connecting` / `disconnecting` additions. Native behaviour is unchanged — Android still reports only connected / disconnected.

## 0.2.0

- Platform method-channel tracing now goes to `BluebirdPlatform.logger` (at `Level.FINEST`); `setLogLevel` no longer takes a `color` argument.
- Surface a peer's ATT Error Response as `attError` (with the raw ATT code), distinct from local GATT stack/link failures (`androidError`).

## 0.1.0

- Initial release.
