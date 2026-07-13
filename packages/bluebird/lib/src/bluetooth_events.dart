import 'package:flutter/foundation.dart';

import 'bluebird.dart';
import 'bluetooth_characteristic.dart';
import 'bluetooth_device.dart';
import 'bluetooth_utils.dart';

/// Base of all app-level events. Sealed, so `switch`es over events are
/// compiler-checked for exhaustiveness.
sealed class BluebirdEvent {}

final class OnDetachedFromEngineEvent extends BluebirdEvent {
  @internal
  OnDetachedFromEngineEvent();
}

final class OnScanAdvertisementEvent extends BluebirdEvent {
  final ScanResult advertisement;

  @internal
  OnScanAdvertisementEvent(this.advertisement);
}

final class OnScanFailedEvent extends BluebirdEvent {
  final int errorCode;
  final String errorString;

  @internal
  OnScanFailedEvent(this.errorCode, this.errorString);
}

final class OnAdapterStateChangedEvent extends BluebirdEvent {
  final BluetoothAdapterState adapterState;

  @internal
  OnAdapterStateChangedEvent(this.adapterState);
}

sealed class BluebirdDeviceEvent extends BluebirdEvent {
  final BluetoothDevice device;

  BluebirdDeviceEvent(this.device);
}

final class OnConnectionStateChangedEvent extends BluebirdDeviceEvent {
  final BluetoothConnectionState connectionState;

  /// The disconnect reason, if [connectionState] is disconnected
  final DisconnectReason? disconnectReason;

  @internal
  OnConnectionStateChangedEvent(super.device, this.connectionState, this.disconnectReason);
}

final class OnMtuChangedEvent extends BluebirdDeviceEvent {
  final int mtu;

  @internal
  OnMtuChangedEvent(super.device, this.mtu);
}

final class OnServicesResetEvent extends BluebirdDeviceEvent {
  @internal
  OnServicesResetEvent(super.device);
}

/// Base of characteristic value events — a value observed for a characteristic,
/// whether from notify/indicate ([OnCharacteristicNotifiedEvent]) or a read
/// ([OnCharacteristicReadEvent]). Filter this base to observe *all* values;
/// filter a subtype to observe just one kind.
sealed class OnCharacteristicValueEvent extends BluebirdDeviceEvent {
  /// the relevant characteristic
  final BluetoothCharacteristic characteristic;

  /// the value
  final List<int> value;

  @internal
  OnCharacteristicValueEvent(this.characteristic, this.value) : super(characteristic.device);
}

/// A value received via notify/indicate.
final class OnCharacteristicNotifiedEvent extends OnCharacteristicValueEvent {
  @internal
  OnCharacteristicNotifiedEvent(super.characteristic, super.value);
}

/// The result of a [BluetoothCharacteristic.read].
final class OnCharacteristicReadEvent extends OnCharacteristicValueEvent {
  @internal
  OnCharacteristicReadEvent(super.characteristic, super.value);
}

final class OnNameChangedEvent extends BluebirdDeviceEvent {
  final String name;

  @internal
  OnNameChangedEvent(super.device, this.name);
}

final class OnBondStateChangedEvent extends BluebirdDeviceEvent {
  final BluetoothBondState state;
  final BluetoothBondState? prevState;

  @internal
  OnBondStateChangedEvent(super.device, this.state, this.prevState);
}
