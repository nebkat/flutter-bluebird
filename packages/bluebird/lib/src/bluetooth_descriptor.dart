// Copyright 2017-2023, Charles Weinberger & Paul DeMarco.
// All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:flutter/foundation.dart';
import 'package:bluebird_platform_interface/bluebird_platform_interface.dart';

import 'bluetooth_attribute.dart';
import 'bluetooth_characteristic.dart';

class BluetoothDescriptor extends BluetoothAttribute {
  final BluetoothCharacteristic characteristic;

  BluetoothDescriptor.fromProto(BmBluetoothDescriptor p, this.characteristic)
      : super(device: characteristic.device, id: BluetoothAttributeId(Uuid(p.uuid)));

  @internal
  BmDescriptorRef get bm => BmDescriptorRef(characteristic: characteristic.bm, uuid: uuid);

  /// Retrieves the value of a specified descriptor
  Future<List<int>> read({Duration timeout = const Duration(seconds: 15)}) =>
      device.invoke("readDescriptor", (p) => p.readDescriptor(device.remoteId, bm), timeout: timeout);

  /// Writes the value of a descriptor
  Future<void> write(List<int> value, {Duration timeout = const Duration(seconds: 15)}) => device.invoke(
      "writeDescriptor", (p) => p.writeDescriptor(device.remoteId, bm, Uint8List.fromList(value)),
      timeout: timeout);

  @override
  String toString() {
    return '${(BluetoothDescriptor)}{'
        'uuid: $uuid'
        '}';
  }
}
