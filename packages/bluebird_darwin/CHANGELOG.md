## Unreleased

- Added a watchdog to `connect`. CoreBluetooth never gives up on a connection attempt of its own accord, so a peripheral that is powered off or out of range left the call outstanding forever — and the device stuck in `connecting` with its slot occupied, which failed every later attempt with `operationInProgress`. An attempt nothing else cancels is now abandoned after 60s: the connection is canceled, the peripheral's state is torn down, and the call fails with `timeout`. It sits above the 35s default `BluetoothDevice.connect` applies, so it only ever acts as a backstop.
- Implemented `getPermission` from the static `CBManager.authorization`, which needs no central manager and so raises no permission prompt as a side effect. `denied` and `restricted` both report as `permanentlyDenied`: iOS asks once and never again.

## 0.4.4

- Fixed every non-`poweredOn` adapter state being reported as `adapterOff`. `unauthorized` now surfaces as `permissionDenied` and `unsupported` as `unsupported`, from `startScan`, `connect`, and the operations failed when the adapter goes away mid-flight.

## 0.4.0

- Added L2CAP connection-oriented channel support (CoreBluetooth `openL2CAPChannel`).

## 0.3.0

- Regenerated for the `BluetoothConnectionState` `connecting` / `disconnecting` additions. Native behaviour is unchanged — CoreBluetooth still reports only connected / disconnected.

## 0.2.1

- Writes without response now wait for CoreBluetooth's flow control (`canSendWriteWithoutResponse`) to open before enqueuing, instead of failing with a "you must slow down" error. `write(withoutResponse: true)` applies backpressure and resolves once the stack accepts the bytes, matching the Android and web behaviour.

## 0.2.0

- Platform method-channel tracing now goes to `BluebirdPlatform.logger` (at `Level.FINEST`); `setLogLevel` no longer takes a `color` argument.
- Surface a peer's ATT Error Response (`CBATTErrorDomain`) as `attError` (with the raw ATT code), distinct from other CoreBluetooth failures (`darwinError`).

## 0.1.0

- Initial release.
