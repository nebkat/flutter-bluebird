# Mocking guide

How to mock `Bluebird` for testing.

## Overview

Since version [1.10.0](https://pub.dev/packages/bluebird/changelog#1100), `Bluebird.instance` has been deprecated in favor of static functions. 

Therefore, to mock Bluebird you must:

1. Wrap `Bluebird` in a mockable non-static class
2. Add your mocked functions to the mockable class.
2. Use the mockable class in your code

A full example is [here](https://dsavir-h.medium.com/mocking-bluetooth-in-flutter-updated-cb3b9484ae02).

## Mockable class

Create the following class:

```dart
import '../bluebird.dart';

/// Wrapper for Bluebird in order to easily mock it
/// Wraps all static calls for testing purposes
class BluebirdMockable {
  Future<void> startScan({
    List<Guid> withServices = const [],
    Duration? timeout,
    Duration? removeIfGone,
    bool oneByOne = false,
    bool androidUsesFineLocation = false,
  }) {
    return Bluebird.startScan(
        withServices: withServices,
        timeout: timeout,
        removeIfGone: removeIfGone,
        oneByOne: oneByOne,
        androidUsesFineLocation: androidUsesFineLocation);
  }

  Stream<BluetoothAdapterState> get adapterState {
    return Bluebird.adapterState;
  }

  Stream<List<ScanResult>> get scanResults {
    return Bluebird.scanResults;
  }

  bool get isScanningNow {
    return Bluebird.isScanningNow;
  }

  Stream<bool> get isScanning {
    return Bluebird.isScanning;
  }

  Future<void> stopScan() {
    return Bluebird.stopScan();
  }

  void setLogLevel(LogLevel level, {color = true}) {
    return Bluebird.setLogLevel(level, color: color);
  }

  LogLevel get logLevel {
    return Bluebird.logLevel;
  }

  Future<bool> get isSupported {
    return Bluebird.isSupported;
  }

  Future<String> get adapterName {
    return Bluebird.adapterName;
  }

  Future<void> turnOn({int timeout = 60}) {
    return Bluebird.turnOn(timeout: timeout);
  }

  List<BluetoothDevice> get connectedDevices {
    return Bluebird.connectedDevices;
  }

  Future<List<BluetoothDevice>> get systemDevices {
    return Bluebird.systemDevices;
  }

  Future<PhySupport> getPhySupport() {
    return Bluebird.getPhySupport();
  }

  Future<List<BluetoothDevice>> get bondedDevices {
    return Bluebird.bondedDevices;
  }
}
```

## Mock the wrapper class

Using e.g. [Mockito](https://pub.dev/packages/mockito), create a mock for the `BluebirdMockable` class, and build your tests and stubs.

## Create instance

Use the mockable class where needed, e.g. in `main.dart`:

```dart
void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  MyApp({Key? key}) : super(key: key);
  //instance of Bluebird that will be passed
  //throughout the app as necessary
  BluebirdMockable bluePlusMockable = BluebirdMockable();//<--

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'My app',
      theme: ThemeData(
        primarySwatch: Colors.lightGreen,
      ),
      home:  FindDevicesScreen(
        bluePlusMockable: bluePlusMockable,
      );
    );
  }
}
```

## Use mock instead of Bluebird

Within your code, replace all calls to `Bluebird` with the mockable instance, e.g.:  
`Bluebird.isScanning` --> `bluePlusMockable.isScanning`  
`Bluebird.startScan` --> `bluePlusMockable.startScan`  
`Bluebird.scanResults` --> `bluePlusMockable.scanResults`  
etc.

## Example

Detailed example is [here](https://dsavir-h.medium.com/mocking-bluetooth-in-flutter-updated-cb3b9484ae02).
