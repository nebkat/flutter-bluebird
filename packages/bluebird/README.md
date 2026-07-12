# bluebird

Bluetooth Low Energy plugin for Flutter.

| Android | iOS | macOS |
| :-----: | :-: | :---: |
|    ✅    | ✅  |  ✅   |

## Install

```yaml
dependencies:
  bluebird: ^1.0.0
```

## Setup

**Android** — add to `android/app/src/main/AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.BLUETOOTH_SCAN" android:usesPermissionFlags="neverForLocation" />
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
<!-- for Android 11 and below -->
<uses-permission android:name="android.permission.BLUETOOTH" android:maxSdkVersion="30" />
<uses-permission android:name="android.permission.BLUETOOTH_ADMIN" android:maxSdkVersion="30" />
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" android:maxSdkVersion="30" />
```

If you scan to derive location, drop `neverForLocation` and keep `ACCESS_FINE_LOCATION`.

**iOS / macOS** — add to `Info.plist`:

```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>Uses Bluetooth to connect to nearby devices.</string>
```

On macOS also enable the Bluetooth capability in your app's entitlements.

## Usage

### Adapter state

```dart
if (await Bluebird.isSupported == false) return;

Bluebird.adapterState.listen((state) {
  print(state); // on, off, unauthorized, ...
});
```

### Scan

```dart
final sub = Bluebird.onScanResults.listen((results) {
  for (final r in results) {
    print('${r.device.remoteId}: ${r.advertisementData.advName} (${r.rssi})');
  }
});
Bluebird.cancelWhenScanComplete(sub);

await Bluebird.startScan(
  withServices: [Uuid('180d')], // optional filters
  timeout: const Duration(seconds: 15),
);
```

`scanResults` accumulates results for the current scan; `onScanResults` skips previously
cached results. Call `Bluebird.stopScan()` to stop early.

### Connect

```dart
await device.connect();

device.connectionState.listen((state) {
  if (state == BluetoothConnectionState.disconnected) {
    print('disconnected: ${device.disconnectReason}');
  }
});

await device.disconnect();
```

`connect()` completes once connected (or throws on timeout/failure). Reconnect the same
`BluetoothDevice` instance to reconnect.

### Services & characteristics

```dart
final services = await device.discoverServices();

final c = services
    .firstWhere((s) => s.uuid == Uuid('180f'))
    .characteristics
    .firstWhere((c) => c.uuid == Uuid('2a19'));

// read
final value = await c.read();

// write
await c.write([0x01, 0x02], withoutResponse: false);

// subscribe (enables notify/indicate on first listen)
c.notifications.listen((value) => print(value));
```

Descriptors work the same way via `characteristic.descriptors` with `read()` / `write()`.

### MTU (Android)

```dart
await device.requestMtu(512);
device.mtu.listen((mtu) => print(mtu));
```

## Notes

- `Uuid` accepts 16-, 32-, or 128-bit forms and compares by value, so
  `Uuid('180d') == Uuid('0000180d-0000-1000-8000-00805f9b34fb')`.
- One GATT operation runs at a time per app; calls are queued automatically.
- Some methods are Android-only (`requestMtu`, bonding, PHY, `clearGattCache`) and throw
  `BluebirdException` elsewhere.

This is a [federated plugin](https://docs.flutter.dev/packages-and-plugins/developing-packages#federated-plugins):
`bluebird` is the app-facing package; platform code lives in `bluebird_android` (Kotlin)
and `bluebird_darwin` (Swift).
