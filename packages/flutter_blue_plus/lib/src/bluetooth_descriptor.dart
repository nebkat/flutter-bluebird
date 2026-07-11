// Copyright 2017-2023, Charles Weinberger & Paul DeMarco.
// All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart';

import 'bluetooth_attribute.dart';
import 'bluetooth_characteristic.dart';
import 'flutter_blue_plus.dart';
import 'utils.dart';

class BluetoothDescriptor extends BluetoothAttribute {
  final BluetoothCharacteristic characteristic;

  BluetoothDescriptor.fromProto(BmBluetoothDescriptor p, this.characteristic)
      : super(device: characteristic.device, uuid: p.uuid);

  @override
  BluetoothAttribute? get parentAttribute => characteristic;

  /// Retrieves the value of a specified descriptor
  Future<List<int>> read({Duration timeout = const Duration(seconds: 15)}) async {
    device.ensureConnected("readDescriptor");

    // Only allow a single ble operation to be underway at a time
    return Mutex.global.protect(() async {
      final request = BmReadDescriptorRequest(
        address: device.remoteId,
        identifier: identifierPath,
      );

      final response = await FlutterBluePlus.invoke((p) => p.readDescriptor(request))
          .fbpEnsureAdapterIsOn("readDescriptor")
          .fbpEnsureDeviceIsConnected(device, "readDescriptor")
          .fbpTimeout(timeout, "readDescriptor");

      return response.value;
    });
  }

  /// Writes the value of a descriptor
  Future<void> write(List<int> value, {Duration timeout = const Duration(seconds: 15)}) async {
    device.ensureConnected("writeDescriptor");

    // Only allow a single ble operation to be underway at a time
    await Mutex.global.protect(() async {
      final request = BmWriteDescriptorRequest(
        address: device.remoteId,
        identifier: identifierPath,
        value: value,
      );

      FlutterBluePlus.invoke((p) => p.writeDescriptor(request))
          .fbpEnsureAdapterIsOn("writeDescriptor")
          .fbpEnsureDeviceIsConnected(device, "writeDescriptor")
          .fbpTimeout(timeout, "writeDescriptor");
    });
  }

  @override
  String toString() {
    return '${(BluetoothDescriptor)}{'
        'uuid: $uuid'
        '}';
  }
}
