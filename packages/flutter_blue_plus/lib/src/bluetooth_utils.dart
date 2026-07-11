import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart';

/// State of the bluetooth adapter.
enum BluetoothAdapterState { unknown, unavailable, unauthorized, turningOn, on, turningOff, off }

class DisconnectReason {
  final int? code; // specific to platform
  final String? description;
  DisconnectReason(this.code, this.description);
  @override
  String toString() => 'DisconnectReason{'
      'code: $code, '
      '$description'
      '}';
}

enum BluetoothConnectionState {
  disconnected,
  connected,
}

BluetoothConnectionState bmToConnectionState(BmConnectionStateEnum value) => switch (value) {
      BmConnectionStateEnum.disconnected => BluetoothConnectionState.disconnected,
      BmConnectionStateEnum.connected => BluetoothConnectionState.connected
    };

BluetoothAdapterState bmToAdapterState(BmAdapterStateEnum value) => switch (value) {
      BmAdapterStateEnum.unknown => BluetoothAdapterState.unknown,
      BmAdapterStateEnum.unavailable => BluetoothAdapterState.unavailable,
      BmAdapterStateEnum.unauthorized => BluetoothAdapterState.unauthorized,
      BmAdapterStateEnum.turningOn => BluetoothAdapterState.turningOn,
      BmAdapterStateEnum.on => BluetoothAdapterState.on,
      BmAdapterStateEnum.turningOff => BluetoothAdapterState.turningOff,
      BmAdapterStateEnum.off => BluetoothAdapterState.off
    };

BmConnectionPriorityEnum bmFromConnectionPriority(ConnectionPriority value) => switch (value) {
      ConnectionPriority.balanced => BmConnectionPriorityEnum.balanced,
      ConnectionPriority.high => BmConnectionPriorityEnum.high,
      ConnectionPriority.lowPower => BmConnectionPriorityEnum.lowPower
    };

// [none] no bond
// [bonding] bonding is in progress
// [bonded] bond success
enum BluetoothBondState { none, bonding, bonded }

BluetoothBondState bmToBondState(BmBondStateEnum value) => switch (value) {
      BmBondStateEnum.none => BluetoothBondState.none,
      BmBondStateEnum.bonding => BluetoothBondState.bonding,
      BmBondStateEnum.bonded => BluetoothBondState.bonded
    };

enum ConnectionPriority { balanced, high, lowPower }

enum Phy {
  le1m,
  le2m,
  leCoded;

  int get mask => switch (this) {
        Phy.le1m => 1,
        Phy.le2m => 2,
        Phy.leCoded => 3,
      };
}

enum PhyCoding { noPreferred, s2, s8 }
