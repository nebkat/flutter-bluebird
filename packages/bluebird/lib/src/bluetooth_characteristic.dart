// Copyright 2017-2023, Charles Weinberger & Paul DeMarco.
// All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:bluebird_platform_interface/bluebird_platform_interface.dart';

import 'bluetooth_attribute.dart';
import 'bluetooth_descriptor.dart';
import 'bluetooth_events.dart';
import 'bluetooth_service.dart';
import 'bluebird.dart';
import 'utils.dart';

class BluetoothCharacteristic extends BluetoothAttribute {
  final BluetoothService service;
  final CharacteristicProperties properties;
  late final List<BluetoothDescriptor> descriptors;

  @internal
  BluetoothCharacteristic.fromProto(BmBluetoothCharacteristic p, this.service)
      : properties = p.properties,
        super(device: service.device, id: BluetoothAttributeId.fromBm(p.id)) {
    descriptors = p.descriptors.map((d) => BluetoothDescriptor.fromProto(d, this)).toList();
  }

  @internal
  BmCharacteristicRef get bm => BmCharacteristicRef(service: service.bm, characteristic: id.bm);

  late final StreamController<List<int>> _streamController = StreamController<List<int>>.broadcast(
    onListen: () async {
      try {
        await setNotifyValue(true);
      } catch (e, stack) {
        _streamController.addError(e, stack);
      }
    },
    onCancel: () async {
      if (device.isDisconnected) return;
      try {
        await setNotifyValue(false);
      } catch (e, stack) {
        _streamController.addError(e, stack);
      }
    },
  );

  Stream<List<int>> get notifications => _streamController.stream;

  /// Push a value received via notify/indicate (called from the device's
  /// platform event routing).
  @internal
  void handleReceivedValue(List<int> value) {
    _streamController.add(value);
  }

  /// convenience accessor
  BluetoothDescriptor? get cccd => descriptors.where((d) => d.uuid == Uuids.cccdDescriptor).firstOrNull;

  /// read a characteristic
  Future<List<int>> read({Duration timeout = const Duration(seconds: 15)}) async {
    final value =
        await device.invoke("readCharacteristic", (p) => p.readCharacteristic(device.remoteId, bm), timeout: timeout);

    // read results are delivered via the returned future (not a platform
    // event), so emit the app-level event ourselves
    Bluebird.emitEvent(OnCharacteristicReceivedEvent(this, value));

    return value;
  }

  /// Writes a characteristic.
  ///  - [withoutResponse]:
  ///       If `true`, the write is not guaranteed and always returns immediately with success.
  ///       If `false`, the write returns error on failure.
  ///  - [allowLongWrite]: if set, larger writes > MTU are allowed (up to 512 bytes).
  ///       This should be used with caution.
  ///         1. it can only be used *with* response
  ///         2. the peripheral device must support the 'long write' ble protocol.
  ///         3. Interrupted transfers can leave the characteristic in a partially written state
  ///         4. If the mtu is small, it is very very slow.
  Future<void> write(
    List<int> value, {
    bool withoutResponse = false,
    bool allowLongWrite = false,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    if (withoutResponse && allowLongWrite) {
      throw ArgumentError("cannot longWrite withoutResponse, not allowed on iOS or Android");
    }

    final writeType = withoutResponse ? BmWriteType.withoutResponse : BmWriteType.withResponse;
    await device.invoke("writeCharacteristic",
        (p) => p.writeCharacteristic(device.remoteId, bm, writeType, allowLongWrite, Uint8List.fromList(value)),
        timeout: timeout);
  }

  /// Sets notifications or indications for the characteristic.
  ///   - If a characteristic supports both notifications and indications,
  ///     we use notifications. This is a limitation of CoreBluetooth on iOS.
  ///   - [forceIndications] Android Only. force indications to be used instead of notifications.
  /// Returns the platform's result: `false` if the device has no CCCD
  /// descriptor (notifications enabled locally only), `true` otherwise.
  Future<bool> setNotifyValue(
    bool notify, {
    Duration timeout = const Duration(seconds: 15),
    bool forceIndications = false,
  }) {
    if (System.isDarwin) {
      assert(forceIndications == false, "iOS & macOS do not support forcing indications");
    }

    return device.invoke("setNotifyValue", (p) => p.setNotifyValue(device.remoteId, bm, forceIndications, notify),
        timeout: timeout);
  }

  @override
  String toString() {
    return '${(BluetoothCharacteristic)}{'
        'uuid: $uuid, '
        'properties: ${properties.describe()}, '
        'descriptors: $descriptors'
        '}';
  }
}

/// The pigeon-generated properties class is used directly; this alias keeps
/// the public name. `describe()` gives a compact human-readable form.
typedef CharacteristicProperties = BmCharacteristicProperties;

extension CharacteristicPropertiesDescribe on BmCharacteristicProperties {
  /// compact list of the enabled flags, e.g. `[read, notify]`
  String describe() => "[${[
        if (broadcast) 'broadcast',
        if (read) 'read',
        if (writeWithoutResponse) 'writeWithoutResponse',
        if (write) 'write',
        if (notify) 'notify',
        if (indicate) 'indicate',
        if (authenticatedSignedWrites) 'authenticatedSignedWrites',
        if (extendedProperties) 'extendedProperties',
        if (notifyEncryptionRequired) 'notifyEncryptionRequired',
        if (indicateEncryptionRequired) 'indicateEncryptionRequired'
      ].join(", ")}]";
}
