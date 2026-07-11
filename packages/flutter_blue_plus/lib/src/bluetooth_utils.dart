import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart';

/// State of the bluetooth adapter.
typedef BluetoothAdapterState = BmAdapterStateEnum;

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

typedef BluetoothConnectionState = BmConnectionStateEnum;

/// Bond state of a device.
///
/// [BluetoothBondState.none] no bond
/// [BluetoothBondState.bonding] bonding is in progress
/// [BluetoothBondState.bonded] bond success
typedef BluetoothBondState = BmBondStateEnum;

typedef ConnectionPriority = BmConnectionPriorityEnum;

enum Phy {
  le1m,
  le2m,
  leCoded;

  // android PHY_LE_*_MASK constants: 1M=1, 2M=2, CODED=4 (bit flags, not values)
  int get mask => switch (this) {
        Phy.le1m => 1,
        Phy.le2m => 2,
        Phy.leCoded => 4,
      };
}

enum PhyCoding { noPreferred, s2, s8 }
