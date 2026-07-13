// Copyright 2017-2023, Charles Weinberger & Paul DeMarco.
// Copyright 2026, Nebojša Cvetković (nebkat).
// All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:flutter/foundation.dart';
import 'package:bluebird_platform_interface/bluebird_platform_interface.dart';

import 'bluebird.dart';
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

  /// The device's discovery timestamp when this attribute was built. It goes
  /// stale once the device runs a newer discovery (see [isValid]).
  final DateTime _discovery;

  BluetoothAttribute({required this.device, required this.id}) : _discovery = device.discoveryToken;

  Uuid get uuid => id.uuid;

  /// Platform-opaque instance token disambiguating duplicate uuids
  /// (null for descriptors, which are uuid-unique within a characteristic).
  int? get index => id.index;

  /// A stable, human-readable type name for diagnostics. Hardcoded per subtype
  /// rather than derived from [runtimeType], which is minified/obfuscated in
  /// release and web builds.
  @internal
  String get typeLabel;

  /// Whether this attribute belongs to the device's current GATT table.
  ///
  /// Every [BluetoothDevice.discoverServices] — and every services reset —
  /// stamps a new discovery. Each attribute captures the discovery it was found
  /// under, so a reference held across a (re-)discovery reports `false` here and
  /// throws if used. Re-fetch from [BluetoothDevice.services].
  bool get isValid => identical(_discovery, device.discoveryToken);

  /// Throws if this attribute has been superseded by a (re-)discovery, so a
  /// stale reference fails loudly instead of silently operating on a removed
  /// attribute.
  @internal
  void requireValid(String method) {
    if (isValid) return;
    throw BluebirdException(
      method,
      BluebirdErrorCode.invalidIdentifier,
      "$typeLabel $id is stale: it is from the discovery at $_discovery, but the "
      "device's current discovery is ${device.discoveryToken}. "
      "Re-fetch it from device.services.",
    );
  }
}
