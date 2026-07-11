// Copyright 2017-2023, Charles Weinberger & Paul DeMarco.
// All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:flutter/foundation.dart';
import 'package:bluebird_platform_interface/bluebird_platform_interface.dart';

import 'bluetooth_attribute.dart';
import 'bluetooth_characteristic.dart';
import 'bluetooth_device.dart';
import 'bluebird.dart';

class BluetoothService extends BluetoothAttribute {
  final bool isPrimary;
  late final List<BluetoothService> includedServices;
  late final List<BluetoothCharacteristic> characteristics;

  /// The primary service that includes this one (secondary services only).
  BluetoothService? _parentService;

  bool get isSecondary => !isPrimary;

  @internal
  BluetoothService.fromProto(BluetoothDevice device, BmBluetoothService p)
      : isPrimary = p.isPrimary,
        super(device: device, id: BluetoothAttributeId.fromBm(p.id)) {
    characteristics = p.characteristics.map((c) => BluetoothCharacteristic.fromProto(c, this)).toList();
  }

  @internal
  BmServiceRef get bm => BmServiceRef(service: id.bm, parentService: _parentService?.id.bm);

  @internal
  static List<BluetoothService> constructServices(BluetoothDevice device, List<BmBluetoothService> protos) {
    final List<BluetoothService> services = [];
    Map<BluetoothService, List<BmServiceRef>> includedServicesMap = {};
    for (final bmService in protos) {
      final service = BluetoothService.fromProto(device, bmService);
      services.add(service);
      includedServicesMap[service] = bmService.includedServices;
    }

    for (final entry in includedServicesMap.entries) {
      final service = entry.key;
      final includedRefs = entry.value;
      service.includedServices = includedRefs.map((included) {
        final includedId = BluetoothAttributeId.fromBm(included.service);
        final includedService = services.where((s) => s.id == includedId).firstOrNull;
        if (includedService == null) {
          throw BluebirdException(
              "constructServices", BluebirdErrorCode.serviceNotFound, "service not found: ${included.service.uuid}");
        }
        if (includedService.isSecondary) {
          includedService._parentService ??= service;
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
