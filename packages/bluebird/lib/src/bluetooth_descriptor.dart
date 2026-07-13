// Copyright 2017-2023, Charles Weinberger & Paul DeMarco.
// Copyright 2026, Nebojša Cvetković (nebkat).
// All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:bluebird_platform_interface/bluebird_platform_interface.dart';
import 'package:flutter/foundation.dart';

import 'bluetooth_attribute.dart';
import 'bluetooth_characteristic.dart';

class BluetoothDescriptor extends BluetoothAttribute {
  final BluetoothCharacteristic characteristic;

  BluetoothDescriptor.fromProto(BmBluetoothDescriptor p, this.characteristic)
    : super(device: characteristic.device, id: BluetoothAttributeId.fromBm(p.id));

  @override
  @internal
  String get typeLabel => 'BluetoothDescriptor';

  @internal
  BmDescriptorRef get bm => BmDescriptorRef(characteristic: characteristic.bm, id: id.bm);

  /// Retrieves the value of a specified descriptor
  Future<List<int>> read({Duration timeout = const Duration(seconds: 15)}) {
    requireValid("readDescriptor");
    return device.invoke("readDescriptor", (p) => p.readDescriptor(device.remoteId, bm), timeout: timeout);
  }

  /// Writes the value of a descriptor
  Future<void> write(List<int> value, {Duration timeout = const Duration(seconds: 15)}) {
    requireValid("writeDescriptor");
    return device.invoke(
      "writeDescriptor",
      (p) => p.writeDescriptor(device.remoteId, bm, Uint8List.fromList(value)),
      timeout: timeout,
    );
  }

  @override
  String toString() =>
      '$typeLabel{'
      'uuid: $uuid'
      '}';
}
