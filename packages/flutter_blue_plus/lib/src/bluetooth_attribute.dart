// Copyright 2017-2023, Charles Weinberger & Paul DeMarco.
// All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart';

import 'bluetooth_device.dart';

abstract class BluetoothAttribute {
  final BluetoothDevice device;
  final Uuid uuid;

  /// Platform-opaque instance token disambiguating duplicate uuids
  /// (null for descriptors, which are uuid-unique within a characteristic).
  final int? index;

  BluetoothAttribute({
    required this.device,
    required this.uuid,
    this.index,
  });

  @internal
  BmAttributeId get id => BmAttributeId(uuid: uuid.string, instance: index ?? 0);
}
