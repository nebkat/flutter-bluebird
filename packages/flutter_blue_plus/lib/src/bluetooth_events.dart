import 'package:flutter/foundation.dart';

import 'bluetooth_characteristic.dart';
import 'bluetooth_device.dart';
import 'bluetooth_utils.dart';
import 'flutter_blue_plus.dart';

class BluetoothEvents {
  Stream<OnConnectionStateChangedEvent> get onConnectionStateChanged =>
      FlutterBluePlus.extractEventStream<OnConnectionStateChangedEvent>();

  Stream<OnMtuChangedEvent> get onMtuChanged => FlutterBluePlus.extractEventStream<OnMtuChangedEvent>();

  Stream<OnServicesResetEvent> get onServicesReset => FlutterBluePlus.extractEventStream<OnServicesResetEvent>();

  Stream<OnCharacteristicReceivedEvent> get onCharacteristicReceived =>
      FlutterBluePlus.extractEventStream<OnCharacteristicReceivedEvent>();

  Stream<OnNameChangedEvent> get onNameChanged => FlutterBluePlus.extractEventStream<OnNameChangedEvent>();

  Stream<OnBondStateChangedEvent> get onBondStateChanged =>
      FlutterBluePlus.extractEventStream<OnBondStateChangedEvent>();
}

//
// Event Classes
//

// On Detached From Engine
class OnDetachedFromEngineEvent {
  @internal
  OnDetachedFromEngineEvent();
}

// On Scan Response
class OnScanResponseEvent {
  /// the newly received advertisements
  final List<ScanResult> advertisements;

  @internal
  OnScanResponseEvent(this.advertisements);
}

// On Connection State Changed
class OnConnectionStateChangedEvent {
  /// the relevant device
  final BluetoothDevice device;

  /// the new connection state
  final BluetoothConnectionState connectionState;

  /// the disconnect reason, if [connectionState] is disconnected
  final DisconnectReason? disconnectReason;

  @internal
  OnConnectionStateChangedEvent(this.device, this.connectionState, this.disconnectReason);
}

// On Adapter State Changed
class OnAdapterStateChangedEvent {
  /// the new adapter state
  final BluetoothAdapterState adapterState;

  @internal
  OnAdapterStateChangedEvent(this.adapterState);
}

// On Mtu Changed
class OnMtuChangedEvent {
  /// the relevant device
  final BluetoothDevice device;

  /// the new mtu
  final int mtu;

  @internal
  OnMtuChangedEvent(this.device, this.mtu);
}

// On Services Reset
class OnServicesResetEvent {
  /// the relevant device
  final BluetoothDevice device;

  @internal
  OnServicesResetEvent(this.device);
}

// On Characteristic Received
//  - a value received via notify/indicate, or the result of a read
class OnCharacteristicReceivedEvent {
  /// the relevant characteristic
  final BluetoothCharacteristic characteristic;

  /// the new data
  final List<int> value;

  @internal
  OnCharacteristicReceivedEvent(this.characteristic, this.value);

  /// the relevant device
  BluetoothDevice get device => characteristic.device;
}

// On Name Changed
class OnNameChangedEvent {
  /// the relevant device
  final BluetoothDevice device;

  /// the new name
  final String name;

  @internal
  OnNameChangedEvent(this.device, this.name);
}

// On Bond State Changed
class OnBondStateChangedEvent {
  /// the relevant device
  final BluetoothDevice device;

  /// the new bond state
  final BluetoothBondState bondState;

  /// the previous bond state, if known
  final BluetoothBondState? prevState;

  @internal
  OnBondStateChangedEvent(this.device, this.bondState, this.prevState);
}
