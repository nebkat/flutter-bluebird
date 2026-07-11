// Copyright 2017-2023, Charles Weinberger & Paul DeMarco.
// All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart';

import 'bluetooth_attribute.dart';
import 'bluetooth_descriptor.dart';
import 'bluetooth_events.dart';
import 'bluetooth_service.dart';
import 'flutter_blue_plus.dart';
import 'utils.dart';

class BluetoothCharacteristic extends BluetoothAttribute {
  final BluetoothService service;
  final CharacteristicProperties properties;
  late final List<BluetoothDescriptor> descriptors;

  @internal
  BluetoothCharacteristic.fromProto(BmBluetoothCharacteristic p, this.service)
      : properties = CharacteristicProperties.fromProto(p.properties),
        super(device: service.device, uuid: Uuid(p.id.uuid), index: p.id.instance) {
    descriptors = p.descriptors.map((d) => BluetoothDescriptor.fromProto(d, this)).toList();
  }

  @internal
  BmCharacteristicRef get ref => BmCharacteristicRef(service: service.ref, characteristic: id);

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
    device.ensureConnected("readCharacteristics");

    // Only allow a single ble operation to be underway at a time
    return Mutex.global.protect(() async {
      final value = await FlutterBluePlus.invoke((p) => p.readCharacteristic(device.remoteId, ref))
          .fbpEnsureAdapterIsOn("readCharacteristic")
          .fbpEnsureDeviceIsConnected(device, "readCharacteristic")
          .fbpTimeout(timeout, "readCharacteristic");

      // read results are delivered via the returned future (not a platform
      // event), so emit the app-level event ourselves
      FlutterBluePlus.emitEvent(OnCharacteristicReceivedEvent(this, value));

      return value;
    });
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

    device.ensureConnected("writeCharacteristic");

    await Mutex.global.protect(() async {
      final writeType = withoutResponse ? BmWriteType.withoutResponse : BmWriteType.withResponse;

      await FlutterBluePlus.invoke(
              (p) => p.writeCharacteristic(device.remoteId, ref, writeType, allowLongWrite, Uint8List.fromList(value)))
          .fbpEnsureAdapterIsOn("writeCharacteristic")
          .fbpEnsureDeviceIsConnected(device, "writeCharacteristic")
          .fbpTimeout(timeout, "writeCharacteristic");
    });
  }

  /// Sets notifications or indications for the characteristic.
  ///   - If a characteristic supports both notifications and indications,
  ///     we use notifications. This is a limitation of CoreBluetooth on iOS.
  ///   - [forceIndications] Android Only. force indications to be used instead of notifications.
  Future<bool> setNotifyValue(
    bool notify, {
    Duration timeout = const Duration(seconds: 15),
    bool forceIndications = false,
  }) async {
    if (System.isDarwin) {
      assert(forceIndications == false, "iOS & macOS do not support forcing indications");
    }

    device.ensureConnected("setNotifyValue");

    await Mutex.global.protect(() async {
      await FlutterBluePlus.invoke((p) => p.setNotifyValue(device.remoteId, ref, forceIndications, notify))
          .fbpEnsureAdapterIsOn("setNotifyValue")
          .fbpEnsureDeviceIsConnected(device, "setNotifyValue")
          .fbpTimeout(timeout, "setNotifyValue");
    });

    return true;
  }

  @override
  String toString() {
    return '${(BluetoothCharacteristic)}{'
        'uuid: $uuid, '
        'properties: $properties, '
        'descriptors: $descriptors'
        '}';
  }
}

class CharacteristicProperties {
  final bool broadcast;
  final bool read;
  final bool writeWithoutResponse;
  final bool write;
  final bool notify;
  final bool indicate;
  final bool authenticatedSignedWrites;
  final bool extendedProperties;
  final bool notifyEncryptionRequired;
  final bool indicateEncryptionRequired;

  CharacteristicProperties.fromProto(BmCharacteristicProperties p)
      : broadcast = p.broadcast,
        read = p.read,
        writeWithoutResponse = p.writeWithoutResponse,
        write = p.write,
        notify = p.notify,
        indicate = p.indicate,
        authenticatedSignedWrites = p.authenticatedSignedWrites,
        extendedProperties = p.extendedProperties,
        notifyEncryptionRequired = p.notifyEncryptionRequired,
        indicateEncryptionRequired = p.indicateEncryptionRequired;

  @override
  String toString() => "[${[
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
