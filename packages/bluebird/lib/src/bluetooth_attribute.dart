// Copyright 2017-2023, Charles Weinberger & Paul DeMarco.
// All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:flutter/foundation.dart';
import 'package:bluebird_platform_interface/bluebird_platform_interface.dart';

import 'bluetooth_device.dart';

/// Identifies an attribute on a device: a [uuid] plus a platform-opaque
/// [index] disambiguating duplicate uuids.
///
/// This is the object-domain counterpart of the wire-format [BmAttributeId]:
/// the uuid is held as a parsed [Uuid] (form-insensitive equality), converted
/// from/to the wire string form once, at the protocol boundary.
@immutable
class BluetoothAttributeId {
  final Uuid uuid;

  /// Platform-opaque instance token disambiguating duplicate uuids
  /// (null for descriptors, which are uuid-unique within a characteristic).
  final int? index;

  const BluetoothAttributeId(this.uuid, [this.index]);

  @internal
  BluetoothAttributeId.fromBm(BmAttributeId id) : this(id.uuid, id.instance);

  @internal
  BmAttributeId get bm => BmAttributeId(uuid: uuid, instance: index ?? 0);

  @override
  operator ==(Object other) =>
      other is BluetoothAttributeId && uuid == other.uuid && (index ?? 0) == (other.index ?? 0);

  @override
  int get hashCode => Object.hash(uuid, index ?? 0);

  @override
  String toString() => index == null ? '$uuid' : '$uuid:$index';
}

abstract class BluetoothAttribute {
  final BluetoothDevice device;

  /// The uuid:index pair identifying this attribute on [device].
  final BluetoothAttributeId id;

  BluetoothAttribute({required this.device, required this.id});

  Uuid get uuid => id.uuid;

  /// Platform-opaque instance token disambiguating duplicate uuids
  /// (null for descriptors, which are uuid-unique within a characteristic).
  int? get index => id.index;
}
