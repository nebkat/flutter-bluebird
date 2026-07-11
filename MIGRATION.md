
# migration guide

Breaking changes in Bluebird, listed version by version.

## 2.0.0 (unreleased)

Complete rework of the plugin architecture:

* **Federated plugin**: the package is now split into `bluebird` (app-facing),
  `bluebird_platform_interface`, `bluebird_android` (Kotlin), and
  `bluebird_darwin` (Swift, shared iOS/macOS). Web and Linux are parked.
* **Pigeon codegen**: all platform communication is generated from
  `packages/bluebird_platform_interface/pigeons/messages.dart`. The hand-written
  `Bm*` message classes with `toMap`/`fromMap` are gone; pigeon-generated classes are the
  platform interface types.
* **Typed attribute refs**: attributes are addressed by `BmAttributeId` (uuid + platform
  instance token) composed into `BmServiceRef`/`BmCharacteristicRef`/`BmDescriptorRef`,
  replacing the `"uuid:index/uuid:index"` identifier strings.
  `BluetoothAttribute.identifier`/`identifierPath` were removed.
* **True async operations**: native methods now complete their Future when the operation
  actually finishes (including `connect()`, which completes on connection success/failure
  rather than when the request is filed). Operation results no longer arrive as separate
  events that are correlated Dart-side.
* **Events**: unsolicited platform events arrive on a single typed
  `Stream<BmEvent>` (pigeon event channel). `onCharacteristicReceived` on the platform
  interface was renamed `onCharacteristicNotified` and carries notify/indicate values
  only; `read()` results are emitted app-side. Scan failures are a `BmScanFailedEvent`
  rather than an embedded success flag.
* **Errors**: natives throw typed errors with stable string codes (`gatt_error`,
  `cb_error`, `device_disconnected`, `adapter_off`, `user_canceled`, `unsupported`, ...)
  which surface as `BluebirdException`. The `BmStatus` success/errorCode envelope
  is gone.
* **Values are `Uint8List`** end-to-end on the wire; uuids cross as strings.

## 1.8.6
* **renamed:** `BluetoothDevice.id` -> `remoteId`
* **renamed:** `Bluebird.name` -> `adapterName`
* **renamed:** `BluetoothDevice.name` -> `platformName`
* **renamed:** `Bluebird.state` -> `adapterState`
* **renamed:** `BluetoothDevice.state` -> `connectionState`

## 1.9.0

* **Behavior Change:** Android: push to `onValueReceived` when `read()` is called, to match iOS behavior
* **renamed:** `BluetoothCharacteristic.value` -> `lastValueStream`
* **renamed:** `BluetoothDescriptor.value` -> `lastValueStream`
* **renamed:** `BluetoothCharacteristic.onValueChangedStream` -> `onValueReceived`
* **renamed:** `BluetoothDescriptor.onValueChangedStream` -> `onValueReceived`

## 1.10.0

### .instance removed

You no longer need to use `.instance`

i.e. `Bluebird.instance.startScan` becomes `Bluebird.startScan`

### turnOn and turnOff

* they now wait for completion if you use `await`
* they throw on error, instead of returning false

## 1.11.0

* **renamed:** `connectedDevices` -> `systemDevices`

## 1.15.0

### `Bluebird.scan` was removed

**Option 1:** migrate to `Bluebird.startScan` with `oneByOne` parameter

**Option 2:** use the following extension (below)

```
extension Scan on Bluebird {
  static Stream<ScanResult> scan({
    List<Guid> withServices = const [],
    Duration? timeout,
    bool androidUsesFineLocation = false,
  }) {
    if (Bluebird.isScanningNow) {
        throw Exception("Another scan is already in progress");
    }

    final controller = StreamController<ScanResult>();

    var subscription = Bluebird.scanResults.listen(
      (r){if(r.isNotEmpty){controller.add(r.first);}},
      onError: (e, stackTrace) => controller.addError(e, stackTrace),
    );

    Future scanComplete = Bluebird.isScanning.skip(1).where((e) => e == false).first;

    Bluebird.startScan(
      withServices: withServices,
      timeout: timeout,
      removeIfGone: null,
      oneByOne: true,
      androidUsesFineLocation: androidUsesFineLocation,
    );

    scanComplete.whenComplete(() {
      subscription.cancel();
      controller.close();
    });

    return controller.stream;
  }
}
```

---

### `Bluebird.startScan` doesn't return List<ScanResult> anymore

**Option 1:** migrate to `Bluebird.scanResults`. Example code:

```
Stream<BluetoothDevice?> myDeviceStream = Bluebird.scanResults
    .map((list) => list.first)
    .where((r) => r.advertisementData.advName == "myDeviceName")
    .map((r) => r.device);

// start listening before we call startScan so we do not miss the result
Future<BluetoothDevice?> myDeviceFuture = myDeviceStream.first
    .timeout(Duration(seconds: 10))
    .catchError((error) => null);

await Bluebird.startScan(timeout: Duration(seconds: 10), oneByOne:true);

BluetoothDevice? myDevice = await myDeviceFuture;
```

**Option 2:** use this extension

```
extension Scan on Bluebird {
  static Future<List<ScanResult>> startScanWithResult({
    List<Guid> withServices = const [],
    Duration? timeout,
    bool androidUsesFineLocation = false,
  }) async {
    if (Bluebird.isScanningNow) {
      throw Exception("Another scan is already in progress");
    }

    List<ScanResult> output = [];

    var subscription = Bluebird.scanResults.listen((result) {
      output = result;
    }, onError: (e, stackTrace) {
      throw Exception(e);
    });

    Bluebird.startScan(
      withServices: withServices,
      timeout: timeout,
      removeIfGone: null,
      oneByOne: false,
      androidUsesFineLocation: androidUsesFineLocation,
    );

    // wait scan complete
    await Bluebird.isScanning.where((e) => e == false).first;

    subscription.cancel();

    return output;
  }
}
```

---

### `await Bluebird.startScan()` does not wait for scan completion anymore

Use `isScanning` to detect completion instead.

```
await Bluebird.startScan(timeout: Duration(seconds:15));
await Bluebird.isScanning.where((value) => value == false).first;
```

## 1.16.0

* **renamed:** `BluetoothDevice.localName` -> `platformName`
* **deleted:** `BluetoothDevice.type` & `BluetoothDevice.localName` from constructor
* **deleted:** `servicesStream` & `isDiscoveringServices` 

## 1.17.0

* **Behavior Change:** `lastValue` & `lastValueStream` are now updated when `write()` is called

## 1.18.0

* **Breaking Change** bondState: directly expose prevBond instead of lost/failed flags

## 1.20.0

* **renamed:** `connectedSystemDevices` -> `systemDevices`, because they must be re-connected by *your* app.

## 1.20.3

 **Caution:** this release introduces a new function called `connectedDevices`. Before `1.11.0`, there used to be a function with this same name. That older function has since been renamed to `systemDevices`.

## 1.21.0

* **Behavior Change:** only allow a single ble operation at a time.

This change was made to increase reliability, at the cost of throughput.

## 1.22.0

* **Breaking Change:** on android, we now request an mtu of 512 by default during connection.

## 1.22.1 to 1.26.0
These releases changed multiple things but then changed them back. For brevity, here are the actual changes:
* **[Behavior Change]** android: always listen to Services Changed characteristic, to match iOS behavior
* **[Rename]** `device.onServicesChanged` -> `device.onServicesReset`
* **[Remove]** `device.onNameChanged`, in favor of only exposing `events.onNameChanged`
* **[Rename]** events api: most functions & classes were renamed for consistency

## 1.27.0

* **[Breaking Change]** scanning: `continousUpdates` is now false by default - it is not typically needed & hurts perf. 

If your app uses `startScan.removeIfGone`, or your app continually checks the value of `scanResult.timestamp` or `scanResult.rssi`, then you will need to explicitly set `continousUpdates` to true.

## 1.27.2

* **[Rename]** `advertisementData.localName` -> `advertisementData.advName`

## 1.28.0

* **[Breaking Change]** `guid.toString()` now returns 16-bit short uuid when possibe
* **[Breaking Change]** use GUID for `advertisingData.serviceUuids` & `advertisingData.serviceData` instead of String

## 1.29.0

* **[Breaking Change]** scanResults: do not clear results after `stopScan`. If you want results cleared, use `onScanResults` instead.
