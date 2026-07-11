import 'package:flutter/foundation.dart';

import 'bluetooth_characteristic.dart';
import 'bluetooth_device.dart';
import 'bluetooth_utils.dart';
import 'bluebird.dart';

class BluetoothEvents {
  Stream<OnConnectionStateChangedEvent> get onConnectionStateChanged =>
      Bluebird.extractEventStream<OnConnectionStateChangedEvent>();

  Stream<OnMtuChangedEvent> get onMtuChanged => Bluebird.extractEventStream<OnMtuChangedEvent>();

  Stream<OnServicesResetEvent> get onServicesReset => Bluebird.extractEventStream<OnServicesResetEvent>();

  Stream<OnCharacteristicReceivedEvent> get onCharacteristicReceived =>
      Bluebird.extractEventStream<OnCharacteristicReceivedEvent>();

  Stream<OnNameChangedEvent> get onNameChanged => Bluebird.extractEventStream<OnNameChangedEvent>();

  Stream<OnBondStateChangedEvent> get onBondStateChanged =>
      Bluebird.extractEventStream<OnBondStateChangedEvent>();
}

//
// Event Classes
//

/// Base of all app-level events. Sealed, so `switch`es over events are
/// compiler-checked for exhaustiveness.
sealed class BluebirdEvent {
  /// the relevant device, when the event concerns one
  BluetoothDevice? get device => null;
}

/// Base of all events that concern a specific device.
sealed class BluebirdDeviceEvent extends BluebirdEvent {
  @override
  final BluetoothDevice device;

  BluebirdDeviceEvent(this.device);
}

final class OnDetachedFromEngineEvent extends BluebirdEvent {
  @internal
  OnDetachedFromEngineEvent();
}

final class OnScanResponseEvent extends BluebirdEvent {
  /// the newly received advertisements
  final List<ScanResult> advertisements;

  @internal
  OnScanResponseEvent(this.advertisements);
}

final class OnAdapterStateChangedEvent extends BluebirdEvent {
  /// the new adapter state
  final BluetoothAdapterState adapterState;

  @internal
  OnAdapterStateChangedEvent(this.adapterState);
}

final class OnConnectionStateChangedEvent extends BluebirdDeviceEvent {
  /// the new connection state
  final BluetoothConnectionState connectionState;

  /// the disconnect reason, if [connectionState] is disconnected
  final DisconnectReason? disconnectReason;

  @internal
  OnConnectionStateChangedEvent(super.device, this.connectionState, this.disconnectReason);
}

final class OnMtuChangedEvent extends BluebirdDeviceEvent {
  /// the new mtu
  final int mtu;

  @internal
  OnMtuChangedEvent(super.device, this.mtu);
}

final class OnServicesResetEvent extends BluebirdDeviceEvent {
  @internal
  OnServicesResetEvent(super.device);
}

/// A value received via notify/indicate, or the result of a read.
final class OnCharacteristicReceivedEvent extends BluebirdEvent {
  /// the relevant characteristic
  final BluetoothCharacteristic characteristic;

  /// the new data
  final List<int> value;

  @internal
  OnCharacteristicReceivedEvent(this.characteristic, this.value);

  @override
  BluetoothDevice get device => characteristic.device;
}

final class OnNameChangedEvent extends BluebirdDeviceEvent {
  /// the new name
  final String name;

  @internal
  OnNameChangedEvent(super.device, this.name);
}

final class OnBondStateChangedEvent extends BluebirdDeviceEvent {
  /// the new bond state
  final BluetoothBondState bondState;

  /// the previous bond state, if known
  final BluetoothBondState? prevState;

  @internal
  OnBondStateChangedEvent(super.device, this.bondState, this.prevState);
}
