## Unreleased

- GATT operations wait their turn on a per-device queue, since Web Bluetooth rejects one started while another is pending. Operations still waiting when the device disconnects fail with `deviceDisconnected` instead of running on the next connection.

## 0.5.0

- Updated for the new platform interface.

## 0.4.2

- Fixed a spurious `deviceDisconnected` when a device is disconnected and quickly reconnected. The browser dispatches `gattserverdisconnected` asynchronously in response to `disconnect()`, so the delayed event could land on the freshly re-established connection, wipe its attribute cache, and drive it back to `disconnected`. `disconnect()` now treats that event as the single source of truth and waits for it to be handled before returning, so the straggler is consumed before any reconnect begins.

## 0.4.0

- Require `bluebird_platform_interface ^0.4.0`. L2CAP is unsupported on Web.

## 0.3.0

- Require `bluebird_platform_interface ^0.3.0`.

## 0.2.0

- Require `bluebird_platform_interface ^0.2.0`.

## 0.1.0

- Initial release.
