// Copyright 2017-2023, Charles Weinberger & Paul DeMarco.
// Copyright 2026, Nebojša Cvetković (nebkat).
// All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:bluebird_platform_interface/bluebird_platform_interface.dart';
import 'package:flutter/foundation.dart';

import 'bluebird.dart';
import 'bluetooth_attribute.dart';
import 'bluetooth_characteristic.dart';
import 'bluetooth_device.dart';

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

  @override
  @internal
  String get typeLabel => 'BluetoothService';

  @internal
  BmServiceRef get bm => BmServiceRef(service: id.bm, parentService: _parentService?.id.bm);

  /// Builds a fresh service tree from a discovery result. Every call to
  /// [BluetoothDevice.discoverServices] constructs a brand-new tree — old
  /// objects are invalidated rather than reused, because an attribute's identity
  /// token (an Android instance id / iOS object pointer) is not stable enough to
  /// safely re-match across a re-discovery.
  @internal
  static List<BluetoothService> constructServices(BluetoothDevice device, List<BmBluetoothService> protos) {
    final List<BluetoothService> services = [];
    final Map<BluetoothService, List<BmServiceRef>> includedServicesMap = {};
    for (final proto in protos) {
      final service = BluetoothService.fromProto(device, proto);
      services.add(service);
      includedServicesMap[service] = proto.includedServices;
    }

    for (final entry in includedServicesMap.entries) {
      final service = entry.key;
      final includedRefs = entry.value;
      service.includedServices = includedRefs.map((included) {
        final includedId = BluetoothAttributeId.fromBm(included.service);
        final includedService = services.where((s) => s.id == includedId).firstOrNull;
        if (includedService == null) {
          throw BluebirdException(
            "constructServices",
            BluebirdErrorCode.serviceNotFound,
            "service not found: ${included.service.uuid}",
          );
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
  String toString() =>
      '$typeLabel{'
      'uuid: $uuid, '
      'isPrimary: $isPrimary, '
      'characteristics: $characteristics, '
      'includedServices: $includedServices'
      '}';
}
