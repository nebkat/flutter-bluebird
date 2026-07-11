// Copyright 2017-2023, Charles Weinberger & Paul DeMarco.
// All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart';

import 'bluetooth_attribute.dart';
import 'bluetooth_characteristic.dart';
import 'bluetooth_device.dart';
import 'flutter_blue_plus.dart';

class BluetoothService extends BluetoothAttribute {
  final bool isPrimary;
  late final List<BluetoothService> includedServices;
  late final List<BluetoothCharacteristic> characteristics;

  bool get isSecondary => !isPrimary;

  @internal
  BluetoothService.fromProto(BluetoothDevice device, BmBluetoothService p)
      : isPrimary = p.isPrimary,
        super(device: device, uuid: p.uuid, index: p.index) {
    characteristics = p.characteristics.map((c) => BluetoothCharacteristic.fromProto(c, this)).toList();
  }

  @internal
  static List<BluetoothService> constructServices(BluetoothDevice device, List<BmBluetoothService> protos) {
    final List<BluetoothService> services = [];
    Map<BluetoothService, List<String>> includedServicesMap = {};
    for (final bmService in protos) {
      final service = BluetoothService.fromProto(device, bmService);
      services.add(service);
      includedServicesMap[service] = bmService.includedServices;
    }

    for (final entry in includedServicesMap.entries) {
      final service = entry.key;
      final includedServices = entry.value;
      service.includedServices = includedServices.map((identifier) {
        final includedService = services.where((s) => s.identifier == identifier).firstOrNull;
        if (includedService == null) {
          throw FlutterBluePlusException(
              "constructServices", FbpErrorCode.serviceNotFound, "service not found: $identifier");
        }
        return includedService;
      }).toList();
    }

    return services;
  }

  @override
  String toString() {
    return '${(BluetoothService)}{'
        'uuid: $uuid, '
        'isPrimary: $isPrimary, '
        'characteristics: $characteristics, '
        'includedServices: $includedServices'
        '}';
  }
}
