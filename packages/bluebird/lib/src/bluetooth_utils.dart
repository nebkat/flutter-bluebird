import 'package:bluebird_platform_interface/bluebird_platform_interface.dart';

// BluetoothAdapterState, BluetoothConnectionState, BluetoothBondState and
// ConnectionPriority are pure enums shared with the wire protocol — defined in
// the platform interface (pigeon schema) and re-exported here, so there is no
// separate "Bm" variant to convert.
export 'package:bluebird_platform_interface/bluebird_platform_interface.dart'
    show BluetoothAdapterState, BluetoothConnectionState, BluetoothBondState, ConnectionPriority;

class DisconnectReason {
  final int? code; // specific to platform
  final String? description;
  DisconnectReason(this.code, this.description);
  @override
  String toString() =>
      'DisconnectReason{'
      'code: $code, '
      '$description'
      '}';
}

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

  /// The combined bitmask for a set of phys — the bitwise-OR of each [mask].
  static int maskFrom(Set<Phy> phys) => phys.fold(0, (mask, phy) => mask | phy.mask);
}

enum PhyCoding { noPreferred, s2, s8 }

typedef PhySupport = BmPhySupport;
